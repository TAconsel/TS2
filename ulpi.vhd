library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- ULPI link-side bus master for the SMSC USB3300 PHY.
--
-- The PHY is in "output clock" mode: it runs from its own 24 MHz crystal and
-- drives CLK at 60 MHz, so this whole entity -- and everything downstream of
-- it -- lives in the PHY's clock domain, not the board's 50 MHz one.
--
-- Bus rules implemented here (ULPI 1.1):
--
--   * DIR high means the PHY owns DATA.  The link must stop driving in the
--     same cycle DIR rises, so the output enable is combinational on the raw
--     pin, not on the registered copy.  The first cycle after DIR rises is a
--     turnaround and carries nothing.
--   * With DIR high: NXT high = USB receive data, NXT low = an RX CMD status
--     byte.  The exception is the data phase of a register read, which also
--     arrives with NXT low, so RX CMD decoding is suppressed there.
--   * With DIR low the link drives a command byte and holds it until the PHY
--     raises NXT.  0x00 is the idle command.  Register write = 0x80 | addr,
--     register read = 0xC0 | addr, USB transmit = 0x40 | PID.
--   * The PHY consumes one byte for every cycle NXT is high, and it does not
--     wait: a register write sees NXT asserted across two consecutive cycles,
--     the command in the first and the data in the second.  So the flow
--     control below reads the NXT pin directly rather than a registered copy.
--     Going through a register would put the reply a cycle late, and the PHY
--     would take the command byte twice -- which writes the command byte into
--     the addressed register.  Doing that to Function Control clears SuspendM
--     and puts the PHY to sleep, which is exactly what it looked like.
--     The registered copy is still what the receive path uses, because there
--     it has to stay aligned with the registered data.
--   * A transmit is terminated by one cycle of STP with 0x00 on DATA.
--
-- The PHY does sync patterns, NRZI, bit stuffing and EOP.  CRC is the link's
-- job, so CRC16 is generated here over the payload and appended when tx_crc
-- is set (a zero-length data packet correctly gets 0x00 0x00).
--
-- Only full speed is targeted.  That matters for the transmit handshake: at
-- 12 Mbit/s a byte takes 40 ULPI clocks, so NXT is sparse and the byte source
-- has ~40 cycles to produce the next byte.  A high-speed port would have to
-- sustain one byte per clock.

entity ulpi is
    Port (
        clk      : in    STD_LOGIC;   -- 60 MHz, from the PHY
        rst      : in    STD_LOGIC;   -- synchronous, active high

        -- PHY pins.  The data bus is split into in/out/enable rather than an
        -- inout port so that the bring-up logic can take the bus away for its
        -- own connectivity test; the tri-state itself lives one level up.
        d_in     : in    STD_LOGIC_VECTOR(7 downto 0);
        d_out    : out   STD_LOGIC_VECTOR(7 downto 0);
        d_oe     : out   STD_LOGIC;
        ulpi_dir : in    STD_LOGIC;
        ulpi_nxt : in    STD_LOGIC;
        ulpi_stp : out   STD_LOGIC;

        -- Register access.  One outstanding at a time; assert reg_rd or reg_wr
        -- for one cycle while busy is low.
        reg_addr  : in  STD_LOGIC_VECTOR(5 downto 0);
        reg_wdata : in  STD_LOGIC_VECTOR(7 downto 0);
        reg_rd    : in  STD_LOGIC;
        reg_wr    : in  STD_LOGIC;
        reg_rdata : out STD_LOGIC_VECTOR(7 downto 0);
        reg_done  : out STD_LOGIC;
        -- Pulsed instead of reg_done when the PHY took the bus part way
        -- through, or when the transfer simply never finished.  The requester
        -- is expected to reissue: ULPI lets the PHY pre-empt the link at any
        -- time, and it does so the moment anything on the USB lines changes,
        -- so a register write racing a line state change is routine rather
        -- than exceptional.  Retrying a write is safe because writing the same
        -- value twice has no additional effect.
        reg_abort : out STD_LOGIC;
        busy      : out STD_LOGIC;

        -- USB packet transmit.  Pulse tx_req with tx_pid valid.  tx_data must
        -- hold the byte to send next, and tx_ack is combinational: it is high
        -- during the very cycle the byte is taken, so the source advances on
        -- the same clock edge that loads it.  A registered acknowledgement
        -- would leave the source a cycle behind, and since the PHY takes the
        -- first bytes of a packet on consecutive clocks, that cycle is exactly
        -- when it cannot afford to be behind -- the byte still on the bus goes
        -- out a second time.  Dropping tx_valid ends the payload.
        tx_req   : in  STD_LOGIC;
        tx_pid   : in  STD_LOGIC_VECTOR(3 downto 0);
        tx_crc   : in  STD_LOGIC;   -- append CRC16 (data packets)
        tx_data  : in  STD_LOGIC_VECTOR(7 downto 0);
        tx_valid : in  STD_LOGIC;
        tx_ack   : out STD_LOGIC;
        tx_done  : out STD_LOGIC;

        -- USB packet receive, PID byte first.
        rx_active : out STD_LOGIC;
        rx_valid  : out STD_LOGIC;
        rx_data   : out STD_LOGIC_VECTOR(7 downto 0);
        rx_error  : out STD_LOGIC;

        -- Latest line status from the RX CMDs the PHY sends unprompted.
        linestate : out STD_LOGIC_VECTOR(1 downto 0);
        vbus      : out STD_LOGIC_VECTOR(1 downto 0)
    );
end ulpi;

architecture Behavioral of ulpi is

    type state_t is (S_IDLE,
                     S_RW_CMD, S_RW_DATA, S_RW_STP,
                     S_RR_CMD, S_RR_TURN, S_RR_DATA,
                     S_TX_CMD, S_TX_DATA, S_TX_CRC0, S_TX_CRC1, S_TX_STP);
    signal state : state_t := S_IDLE;

    -- Registered pin samples.  dir_q2 exists only to spot the turnaround
    -- cycle, which is the one where dir_q is high but dir_q2 is not.
    signal dir_q, dir_q2, nxt_q : STD_LOGIC := '0';
    signal data_q : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');

    -- The NXT pin itself, for flow control only.  See the note above.
    signal nxt_now : STD_LOGIC;

    signal data_out : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal stp_out  : STD_LOGIC := '0';

    -- A copy of whatever payload byte is currently on the bus, kept only so
    -- the CRC has something to read.  data_out itself must feed nothing but
    -- the pin, or the fitter cannot put it in the I/O cell -- and at 60 MHz
    -- with 9 ns of PHY output delay and 6 ns of setup to meet, the couple of
    -- nanoseconds that saves is the difference between meeting the ULPI
    -- timing and not.
    signal crc_src : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');

    signal crc16 : STD_LOGIC_VECTOR(15 downto 0) := (others => '1');

    -- Backstop for a transfer that never completes -- a NXT that never comes,
    -- say.  Generous: 4096 cycles is 68 us, far longer than any register
    -- transfer, so it never fires in normal operation.
    signal to_cnt : unsigned(11 downto 0) := (others => '0');

    -- True whenever the PHY owns the bus, now or a cycle ago.  Driving during
    -- the cycle DIR falls would collide with the PHY's own turnaround.
    signal oe : STD_LOGIC;

    -- USB CRC16: x^16 + x^15 + x^2 + 1, fed LSB first, so the usual reflected
    -- form with 0xA001.
    function crc16_byte(c : STD_LOGIC_VECTOR(15 downto 0);
                        d : STD_LOGIC_VECTOR(7 downto 0))
        return STD_LOGIC_VECTOR is
        variable v : STD_LOGIC_VECTOR(15 downto 0);
    begin
        v := c xor (x"00" & d);
        for i in 0 to 7 loop
            if v(0) = '1' then
                v := ('0' & v(15 downto 1)) xor x"A001";
            else
                v := '0' & v(15 downto 1);
            end if;
        end loop;
        return v;
    end function;

begin

    nxt_now  <= ulpi_nxt;

    -- High on the cycle a payload byte is actually taken.
    tx_ack   <= '1' when (state = S_TX_CMD or state = S_TX_DATA)
                     and dir_q = '0' and nxt_now = '1' and tx_valid = '1'
                else '0';
    oe       <= '0' when (ulpi_dir = '1' or dir_q = '1') else '1';
    d_oe     <= oe;
    d_out    <= data_out;
    ulpi_stp <= stp_out;

    busy <= '0' when state = S_IDLE else '1';

    process(clk)
        variable crc_next : STD_LOGIC_VECTOR(15 downto 0);
    begin
        if rising_edge(clk) then

            dir_q  <= ulpi_dir;
            dir_q2 <= dir_q;
            nxt_q  <= ulpi_nxt;
            data_q <= d_in;

            reg_done  <= '0';
            reg_abort <= '0';
            tx_done  <= '0';
            rx_valid <= '0';
            rx_error <= '0';
            stp_out  <= '0';

            --------------------------------------------------------------
            -- Receive: anything the PHY sends while it owns the bus, other
            -- than the turnaround cycle and the data phase of a register
            -- read (which the FSM below claims for itself).
            --------------------------------------------------------------
            if dir_q = '1' and dir_q2 = '1' and state /= S_RR_DATA then
                if nxt_q = '1' then
                    rx_data  <= data_q;
                    rx_valid <= '1';
                else
                    -- RX CMD: [1:0] line state, [3:2] VBUS, [5:4] RX event.
                    linestate <= data_q(1 downto 0);
                    vbus      <= data_q(3 downto 2);
                    case data_q(5 downto 4) is
                        when "01"   => rx_active <= '1';
                        when "11"   => rx_active <= '1';
                                       rx_error  <= '1';
                        when others => rx_active <= '0';
                    end case;
                end if;
            end if;

            -- The PHY dropping DIR ends any packet in progress, whether or
            -- not a closing RX CMD arrived.
            if dir_q = '0' then
                rx_active <= '0';
            end if;

            --------------------------------------------------------------
            -- Command FSM
            --------------------------------------------------------------
            case state is

                when S_IDLE =>
                    data_out <= x"00";
                    to_cnt   <= (others => '0');
                    -- Never start while the PHY owns the bus.
                    if ulpi_dir = '0' and dir_q = '0' then
                        if reg_wr = '1' then
                            data_out <= "10" & reg_addr;
                            state    <= S_RW_CMD;
                        elsif reg_rd = '1' then
                            data_out <= "11" & reg_addr;
                            state    <= S_RR_CMD;
                        elsif tx_req = '1' then
                            data_out <= "0100" & tx_pid;
                            crc16    <= (others => '1');
                            state    <= S_TX_CMD;
                        end if;
                    end if;

                ----------------------------------------------------------
                -- Register write
                ----------------------------------------------------------
                when S_RW_CMD =>
                    if dir_q = '1' then          -- PHY pre-empted us
                        reg_abort <= '1';
                        state     <= S_IDLE;
                    elsif nxt_now = '1' then
                        data_out <= reg_wdata;
                        state    <= S_RW_DATA;
                    end if;

                when S_RW_DATA =>
                    if dir_q = '1' then
                        reg_abort <= '1';
                        state     <= S_IDLE;
                    elsif nxt_now = '1' then
                        data_out <= x"00";
                        stp_out  <= '1';
                        state    <= S_RW_STP;
                    end if;

                when S_RW_STP =>
                    reg_done <= '1';
                    state    <= S_IDLE;

                ----------------------------------------------------------
                -- Register read.  After NXT the PHY turns the bus around;
                -- the byte one cycle after DIR rises is the register value.
                ----------------------------------------------------------
                when S_RR_CMD =>
                    if dir_q = '1' then
                        reg_abort <= '1';
                        state     <= S_IDLE;
                    elsif nxt_now = '1' then
                        data_out <= x"00";
                        state    <= S_RR_TURN;
                    end if;

                when S_RR_TURN =>
                    if dir_q = '1' then
                        state <= S_RR_DATA;
                    end if;

                when S_RR_DATA =>
                    reg_rdata <= data_q;
                    reg_done  <= '1';
                    state     <= S_IDLE;

                ----------------------------------------------------------
                -- USB transmit
                ----------------------------------------------------------
                when S_TX_CMD =>
                    if dir_q = '1' then
                        -- Collision: the host started talking first.  Report
                        -- the packet as finished so the sender is not left
                        -- waiting; USB will simply retry the transaction.
                        tx_done <= '1';
                        state   <= S_IDLE;
                    elsif nxt_now = '1' then
                        if tx_valid = '1' then
                            -- Taking the first payload byte counts as a
                            -- consumption too, so that the source is always
                            -- presenting the byte after the one on the wire.
                            data_out <= tx_data;
                            crc_src  <= tx_data;
                            state    <= S_TX_DATA;
                        elsif tx_crc = '1' then
                            data_out <= not crc16(7 downto 0);
                            state    <= S_TX_CRC0;
                        else
                            data_out <= x"00";
                            stp_out  <= '1';
                            state    <= S_TX_STP;
                        end if;
                    end if;

                when S_TX_DATA =>
                    if dir_q = '1' then
                        tx_done <= '1';
                        state   <= S_IDLE;
                    elsif nxt_now = '1' then
                        -- The byte just went out: fold it into the CRC and,
                        -- only if another one is actually taken, tell the
                        -- source to move on.  Acknowledging here when the
                        -- payload has run out would skip a byte of whatever
                        -- comes next.
                        crc_next := crc16_byte(crc16, crc_src);
                        crc16    <= crc_next;
                        if tx_valid = '1' then
                            data_out <= tx_data;
                            crc_src  <= tx_data;
                        elsif tx_crc = '1' then
                            data_out <= not crc_next(7 downto 0);
                            state    <= S_TX_CRC0;
                        else
                            data_out <= x"00";
                            stp_out  <= '1';
                            state    <= S_TX_STP;
                        end if;
                    end if;

                when S_TX_CRC0 =>
                    if dir_q = '1' then
                        tx_done <= '1';
                        state   <= S_IDLE;
                    elsif nxt_now = '1' then
                        data_out <= not crc16(15 downto 8);
                        state    <= S_TX_CRC1;
                    end if;

                when S_TX_CRC1 =>
                    if dir_q = '1' then
                        tx_done <= '1';
                        state   <= S_IDLE;
                    elsif nxt_now = '1' then
                        data_out <= x"00";
                        stp_out  <= '1';
                        state    <= S_TX_STP;
                    end if;

                when S_TX_STP =>
                    tx_done <= '1';
                    state   <= S_IDLE;

            end case;

            -- Timeout backstop, over the register states only; a USB transmit
            -- is bounded by the packet itself.
            if state = S_RW_CMD or state = S_RW_DATA or state = S_RW_STP
               or state = S_RR_CMD or state = S_RR_TURN or state = S_RR_DATA then
                to_cnt <= to_cnt + 1;
                if to_cnt = 4095 then
                    reg_abort <= '1';
                    state     <= S_IDLE;
                end if;
            end if;

            if rst = '1' then
                state     <= S_IDLE;
                data_out  <= x"00";
                stp_out   <= '0';
                rx_active <= '0';
            end if;

        end if;
    end process;

end Behavioral;
