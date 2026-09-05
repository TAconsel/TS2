library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library work;
use work.usb_desc.all;

-- USB full-speed device: packet layer, transaction layer and endpoint 0.
--
-- Sits on top of the ULPI master, which has already dealt with sync patterns,
-- NRZI, bit stuffing and end-of-packet.  What is left for this level is PID
-- decoding, CRC16, data toggles, the control transfers that get the device
-- enumerated, and steering isochronous audio at the FIFO.
--
-- Full speed only, and that is a choice rather than a limitation: one 1 ms
-- frame carries up to 1023 isochronous bytes and 48 kHz 16-bit stereo needs
-- 192, so high speed would buy nothing while costing the chirp handshake and a
-- one-byte-per-clock datapath.  At 12 Mbit/s a byte occupies 40 ULPI clocks,
-- which is why the descriptor ROM's read latency is invisible here.
--
-- Endpoints:
--
--   0 in/out  control, 64-byte packets
--   1 out     isochronous audio
--   1 in      isochronous feedback, three bytes of 10.14 samples per frame
--
-- Bytes to transmit come out of a small prefetch buffer rather than straight
-- from the descriptor memory.  The PHY does not take a packet's bytes at a
-- steady rate: it swallows the command and the first two payload bytes on
-- consecutive clocks to fill its own FIFO, and only then throttles to one byte
-- per 40 clocks the way full speed implies.  A memory with a cycle of read
-- latency cannot answer that, and the byte that is still on the bus goes out
-- twice -- which corrupts the descriptor while leaving every counter here
-- looking healthy.  Filling three bytes ahead before the packet starts, and
-- refilling one per clock after, covers it.
--
-- Control transfers are retried properly: a data packet is not counted as
-- delivered until the host's ACK comes back, so the transfer position only
-- moves on an ACK and an IN token arriving without one simply re-sends the
-- same chunk.
-- Isochronous transfers get none of that -- no handshake, no retry -- so a
-- packet with a bad CRC is simply dropped and the audio has a hole in it.

entity usb_sie is
    Port (
        clk : in STD_LOGIC;   -- 60 MHz ULPI clock
        rst : in STD_LOGIC;

        -- Packet interface to the ULPI master.
        rx_active : in  STD_LOGIC;
        rx_valid  : in  STD_LOGIC;
        rx_data   : in  STD_LOGIC_VECTOR(7 downto 0);
        rx_error  : in  STD_LOGIC;
        linestate : in  STD_LOGIC_VECTOR(1 downto 0);

        tx_req    : out STD_LOGIC;
        tx_pid    : out STD_LOGIC_VECTOR(3 downto 0);
        tx_crc    : out STD_LOGIC;
        tx_data   : out STD_LOGIC_VECTOR(7 downto 0);
        tx_valid  : out STD_LOGIC;
        tx_ack    : in  STD_LOGIC;
        tx_done   : in  STD_LOGIC;
        tx_busy   : in  STD_LOGIC;

        -- Bus state, for the trace and for the audio clock recovery.
        usb_reset  : out STD_LOGIC;
        configured : out STD_LOGIC;
        streaming  : out STD_LOGIC;
        dev_addr_o : out STD_LOGIC_VECTOR(6 downto 0);
        sof        : out STD_LOGIC;
        frame_no   : out STD_LOGIC_VECTOR(10 downto 0);

        -- Audio payload, one byte at a time, CRC already stripped.
        audio_data  : out STD_LOGIC_VECTOR(7 downto 0);
        audio_valid : out STD_LOGIC;
        -- Pulse at the end of a good audio packet, and separately if one had
        -- to be dropped, so the sink can tell a gap from silence.
        audio_done  : out STD_LOGIC;
        audio_drop  : out STD_LOGIC;

        -- Bring-up counters: setup packets accepted and packets transmitted.
        stat_setup : out unsigned(7 downto 0);
        stat_tx    : out unsigned(7 downto 0);

        -- Rate to report to the host, 10.14 samples per frame.
        fb_value : in unsigned(23 downto 0)
    );
end usb_sie;

architecture Behavioral of usb_sie is

    -- PIDs, low nibble only; the high nibble on the wire is its complement.
    constant PID_OUT   : STD_LOGIC_VECTOR(3 downto 0) := x"1";
    constant PID_IN    : STD_LOGIC_VECTOR(3 downto 0) := x"9";
    constant PID_SOF   : STD_LOGIC_VECTOR(3 downto 0) := x"5";
    constant PID_SETUP : STD_LOGIC_VECTOR(3 downto 0) := x"D";
    constant PID_DATA0 : STD_LOGIC_VECTOR(3 downto 0) := x"3";
    constant PID_DATA1 : STD_LOGIC_VECTOR(3 downto 0) := x"B";
    constant PID_ACK   : STD_LOGIC_VECTOR(3 downto 0) := x"2";
    constant PID_NAK   : STD_LOGIC_VECTOR(3 downto 0) := x"A";
    constant PID_STALL : STD_LOGIC_VECTOR(3 downto 0) := x"E";

    constant EP0_SIZE : natural := 64;
    constant EP_AUDIO : STD_LOGIC_VECTOR(3 downto 0) :=
        std_logic_vector(to_unsigned(EP_AUDIO_OUT, 4));
    constant EP_FB    : STD_LOGIC_VECTOR(3 downto 0) :=
        std_logic_vector(to_unsigned(EP_FEEDBACK_IN, 4));

    ------------------------------------------------------------------
    -- Receive
    ------------------------------------------------------------------
    signal rx_act_q : STD_LOGIC := '0';
    signal pkt_cnt  : unsigned(10 downto 0) := (others => '0');
    signal pid      : STD_LOGIC_VECTOR(3 downto 0) := (others => '0');
    signal pid_ok   : STD_LOGIC := '0';
    -- Sticky for the length of a packet: the PHY saw a bit stuffing or sync
    -- error, so nothing in it can be trusted.
    signal rx_bad   : STD_LOGIC := '0';
    -- True when the packet that just ended was the right length for its kind.
    -- Without this a runt token would be acted on using whatever address and
    -- endpoint the previous one left behind.
    signal len_ok   : STD_LOGIC;

    signal tok_addr : STD_LOGIC_VECTOR(6 downto 0) := (others => '0');
    signal tok_endp : STD_LOGIC_VECTOR(3 downto 0) := (others => '0');
    signal tok_b1   : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');

    -- What the last token addressed, latched so the data packet that follows
    -- it knows where to go.
    signal cur_pid  : STD_LOGIC_VECTOR(3 downto 0) := (others => '0');
    signal cur_endp : STD_LOGIC_VECTOR(3 downto 0) := (others => '0');
    signal for_us   : STD_LOGIC := '0';

    -- Two-byte delay line: the last two bytes of a data packet are the CRC16
    -- and must not reach an endpoint, but the length is not known in advance.
    signal d0, d1    : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal dfill     : unsigned(1 downto 0) := (others => '0');
    signal pay_cnt   : unsigned(10 downto 0) := (others => '0');
    signal crc_rx    : STD_LOGIC_VECTOR(15 downto 0) := (others => '1');
    signal pay_valid : STD_LOGIC := '0';
    signal pay_data  : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    -- Offset of the byte currently in pay_data.  Separate from pay_cnt, which
    -- has already moved on to the next one by the time pay_data is consumed.
    signal pay_idx   : unsigned(10 downto 0) := (others => '0');

    signal setup       : STD_LOGIC_VECTOR(63 downto 0) := (others => '0');
    signal setup_ready : STD_LOGIC := '0';

    ------------------------------------------------------------------
    -- Device state
    ------------------------------------------------------------------
    signal dev_addr : STD_LOGIC_VECTOR(6 downto 0) := (others => '0');
    signal new_addr : STD_LOGIC_VECTOR(6 downto 0) := (others => '0');
    signal addr_pending : STD_LOGIC := '0';
    signal cfg_val  : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal alt_set  : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal se0_cnt  : unsigned(15 downto 0) := (others => '0');

    ------------------------------------------------------------------
    -- Endpoint 0
    ------------------------------------------------------------------
    type ctl_t is (C_IDLE, C_IN_DATA, C_STATUS_IN, C_STATUS_OUT, C_STALL);
    signal ctl : ctl_t := C_IDLE;

    signal ep0_toggle : STD_LOGIC := '0';
    -- Position in the transfer.  These only move when the host acknowledges a
    -- chunk, so re-sending one is simply a matter of not having moved.
    signal in_rom   : STD_LOGIC := '0';
    signal in_addr  : unsigned(DESC_ADDR_BITS-1 downto 0) := (others => '0');
    signal in_rem   : unsigned(15 downto 0) := (others => '0');
    signal in_zlp   : STD_LOGIC := '0';
    signal chunk_len : unsigned(6 downto 0) := (others => '0');
    signal need_ack : STD_LOGIC := '0';
    -- Short replies that come from registers rather than the descriptor ROM:
    -- two bytes for GET_STATUS, three for the isochronous feedback rate.
    signal imm : STD_LOGIC_VECTOR(23 downto 0) := (others => '0');

    -- Prefetch buffer, four bytes, filled ahead of the transmitter.
    type pf_t is array (0 to 3) of STD_LOGIC_VECTOR(7 downto 0);
    signal pf   : pf_t := (others => (others => '0'));
    signal wptr : unsigned(2 downto 0) := (others => '0');
    signal rptr : unsigned(2 downto 0) := (others => '0');
    signal pf_level : unsigned(2 downto 0);
    signal pf_pend  : STD_LOGIC := '0';
    signal rom_out  : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal fetch_addr : unsigned(DESC_ADDR_BITS-1 downto 0) := (others => '0');
    signal fetch_rem  : unsigned(6 downto 0) := (others => '0');
    signal fetch_imm  : STD_LOGIC_VECTOR(23 downto 0) := (others => '0');

    -- The two bytes still sitting in the delay line at the end of a data
    -- packet are its CRC16.  Named rather than concatenated inline so the
    -- expression has an unambiguous type.
    signal crc_pair : STD_LOGIC_VECTOR(15 downto 0);

    ------------------------------------------------------------------
    -- Transmit
    ------------------------------------------------------------------
    type tx_t is (X_IDLE, X_START, X_RUN);
    signal txs : tx_t := X_IDLE;

    signal setup_cnt : unsigned(7 downto 0) := (others => '0');
    signal tx_cnt    : unsigned(7 downto 0) := (others => '0');

    signal tx_req_i : STD_LOGIC := '0';
    signal tx_pid_i : STD_LOGIC_VECTOR(3 downto 0) := (others => '0');
    signal tx_crc_i : STD_LOGIC := '0';

    -- USB CRC16 over the received payload, same reflected form as the
    -- transmit side in the ULPI master.
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

    -- Fields of the eight-byte setup packet.
    alias bmRequestType : STD_LOGIC_VECTOR(7 downto 0) is setup(7 downto 0);
    alias bRequest      : STD_LOGIC_VECTOR(7 downto 0) is setup(15 downto 8);
    alias wValueL       : STD_LOGIC_VECTOR(7 downto 0) is setup(23 downto 16);
    alias wValueH       : STD_LOGIC_VECTOR(7 downto 0) is setup(31 downto 24);
    alias wLengthL      : STD_LOGIC_VECTOR(7 downto 0) is setup(55 downto 48);
    alias wLengthH      : STD_LOGIC_VECTOR(7 downto 0) is setup(63 downto 56);

begin

    crc_pair <= d1 & d0;

    -- A token is a PID and two more bytes, a handshake is a PID on its own,
    -- and a data packet is a PID plus at least its CRC16.
    len_ok <= '1' when ((pid = PID_OUT or pid = PID_IN or pid = PID_SETUP
                         or pid = PID_SOF) and pkt_cnt = 3)
                    or ((pid = PID_DATA0 or pid = PID_DATA1) and pkt_cnt >= 3)
                    or ((pid = PID_ACK or pid = PID_NAK or pid = PID_STALL)
                        and pkt_cnt = 1)
              else '0';

    stat_setup <= setup_cnt;
    stat_tx    <= tx_cnt;

    tx_req <= tx_req_i;
    tx_pid <= tx_pid_i;
    tx_crc <= tx_crc_i;

    pf_level <= wptr - rptr;

    -- A packet's payload runs out when the prefetch buffer does, which by
    -- construction happens only once every byte of the chunk has been fetched.
    -- The ULPI master then appends the CRC16 and stops; a zero-length status
    -- packet is just this with nothing ever put in the buffer.
    tx_valid <= '1' when pf_level > 0 else '0';

    dev_addr_o <= dev_addr;
    configured <= '1' when cfg_val /= x"00" else '0';
    streaming  <= '1' when alt_set /= x"00" else '0';

    -- The byte to send next, one ahead of the one on the wire.
    tx_data <= pf(to_integer(rptr(1 downto 0)));

    ------------------------------------------------------------------
    -- Descriptor ROM.  A registered address infers a memory block; the
    -- register-sourced replies borrow the same output path by muxing into it.
    -- Either way the byte arrives one clock after the address, which is what
    -- the prefetch buffer exists to hide.
    ------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if in_rom = '1' then
                rom_out <= DESC_ROM(to_integer(fetch_addr));
            else
                rom_out <= fetch_imm(7 downto 0);
            end if;
        end if;
    end process;

    ------------------------------------------------------------------
    -- Main
    ------------------------------------------------------------------
    process(clk)
        variable v_addr : unsigned(DESC_ADDR_BITS-1 downto 0);
        variable v_rem  : unsigned(15 downto 0);
        variable v_len  : unsigned(6 downto 0);
        variable len    : unsigned(15 downto 0);
        variable want   : unsigned(15 downto 0);
        variable ok     : boolean;
    begin
        if rising_edge(clk) then

            rx_act_q    <= rx_active;
            usb_reset   <= '0';
            sof         <= '0';
            audio_valid <= '0';
            audio_done  <= '0';
            audio_drop  <= '0';
            pay_valid   <= '0';
            setup_ready <= '0';

            --------------------------------------------------------
            -- Bus reset: SE0 held far longer than any packet gap.
            --------------------------------------------------------
            if linestate = "00" then
                if se0_cnt = 6000 then          -- 100 us at 60 MHz
                    usb_reset  <= '1';
                    dev_addr   <= (others => '0');
                    cfg_val    <= (others => '0');
                    alt_set    <= (others => '0');
                    addr_pending <= '0';
                    ctl        <= C_IDLE;
                    txs        <= X_IDLE;
                    tx_req_i   <= '0';
                end if;
                if se0_cnt <= 6000 then
                    se0_cnt <= se0_cnt + 1;
                end if;
            else
                se0_cnt <= (others => '0');
            end if;

            --------------------------------------------------------
            -- Packet receive
            --------------------------------------------------------
            if rx_active = '1' and rx_act_q = '0' then
                pkt_cnt <= (others => '0');
                dfill   <= (others => '0');
                pay_cnt <= (others => '0');
                crc_rx  <= (others => '1');
                pid_ok  <= '0';
                rx_bad  <= '0';
            end if;

            if rx_error = '1' then
                rx_bad <= '1';
            end if;

            if rx_valid = '1' then
                pkt_cnt <= pkt_cnt + 1;

                if pkt_cnt = 0 then
                    pid <= rx_data(3 downto 0);
                    if rx_data(7 downto 4) = not rx_data(3 downto 0) then
                        pid_ok <= '1';
                    else
                        pid_ok <= '0';
                    end if;

                elsif pid = PID_OUT or pid = PID_IN or pid = PID_SETUP
                       or pid = PID_SOF then
                    -- Token: seven address bits, four endpoint bits and a
                    -- CRC5, sent least significant bit first.
                    if pkt_cnt = 1 then
                        tok_b1 <= rx_data;
                    else
                        tok_addr <= tok_b1(6 downto 0);
                        tok_endp <= rx_data(2 downto 0) & tok_b1(7);
                    end if;

                else
                    -- Data payload, held back two bytes so that the trailing
                    -- CRC16 never reaches an endpoint.
                    if dfill < 2 then
                        if dfill = 0 then
                            d0 <= rx_data;
                        else
                            d1 <= rx_data;
                        end if;
                        dfill <= dfill + 1;
                    else
                        pay_data  <= d0;
                        pay_valid <= '1';
                        crc_rx    <= crc16_byte(crc_rx, d0);
                        pay_idx   <= pay_cnt;
                        pay_cnt   <= pay_cnt + 1;
                        d0 <= d1;
                        d1 <= rx_data;
                    end if;
                end if;
            end if;

            -- Setup packets are only eight bytes, captured straight out of
            -- the delay line as they emerge.
            if pay_valid = '1' and cur_pid = PID_SETUP and pay_idx < 8 then
                setup(to_integer(pay_idx) * 8 + 7 downto
                      to_integer(pay_idx) * 8) <= pay_data;
            end if;

            if pay_valid = '1' and cur_pid = PID_OUT and cur_endp = EP_AUDIO
               and for_us = '1' then
                audio_data  <= pay_data;
                audio_valid <= '1';
            end if;

            --------------------------------------------------------
            -- End of packet
            --------------------------------------------------------
            if rx_active = '0' and rx_act_q = '1'
               and pid_ok = '1' and rx_bad = '0' and len_ok = '1' then
                case pid is

                when PID_SOF =>
                    sof      <= '1';
                    frame_no <= tok_endp(2 downto 0) & tok_b1;

                when PID_IN | PID_OUT | PID_SETUP =>
                    cur_pid  <= pid;
                    cur_endp <= tok_endp;
                    for_us   <= '0';

                    if tok_addr = dev_addr then
                        for_us <= '1';

                        if pid = PID_SETUP then
                            -- A setup packet always wins: it clears any stall
                            -- and restarts the toggle at DATA1.
                            ctl        <= C_IDLE;
                            ep0_toggle <= '1';
                            need_ack   <= '0';

                        elsif pid = PID_IN and tok_endp = x"0" then
                            -- Every packet starts from an empty buffer; the
                            -- transfer position has not moved unless the host
                            -- acknowledged the last chunk, so an unanswered
                            -- chunk simply gets sent again.
                            wptr    <= (others => '0');
                            rptr    <= (others => '0');
                            pf_pend <= '0';
                            case ctl is
                                when C_IN_DATA =>
                                    if in_rem > EP0_SIZE then
                                        v_len := to_unsigned(EP0_SIZE, 7);
                                    else
                                        v_len := in_rem(6 downto 0);
                                    end if;
                                    chunk_len  <= v_len;
                                    fetch_addr <= in_addr;
                                    fetch_rem  <= v_len;
                                    fetch_imm  <= imm;
                                    need_ack   <= '1';
                                    if ep0_toggle = '1' then
                                        tx_pid_i <= PID_DATA1;
                                    else
                                        tx_pid_i <= PID_DATA0;
                                    end if;
                                    tx_crc_i <= '1';
                                    txs      <= X_START;

                                when C_STATUS_IN =>
                                    -- Zero-length status packet, always DATA1.
                                    chunk_len <= (others => '0');
                                    fetch_rem <= (others => '0');
                                    need_ack  <= '1';
                                    tx_pid_i  <= PID_DATA1;
                                    tx_crc_i  <= '1';
                                    txs       <= X_START;

                                when C_STALL =>
                                    fetch_rem <= (others => '0');
                                    tx_pid_i  <= PID_STALL;
                                    tx_crc_i  <= '0';
                                    txs       <= X_START;

                                when others =>
                                    fetch_rem <= (others => '0');
                                    tx_pid_i  <= PID_NAK;
                                    tx_crc_i  <= '0';
                                    txs       <= X_START;
                            end case;

                        elsif pid = PID_IN and tok_endp = EP_FB then
                            -- Isochronous: always answer, never NAK.  The rate
                            -- goes out through the same prefetch path as
                            -- everything else.
                            wptr       <= (others => '0');
                            rptr       <= (others => '0');
                            pf_pend    <= '0';
                            in_rom     <= '0';
                            fetch_imm  <= std_logic_vector(fb_value);
                            fetch_rem  <= to_unsigned(3, 7);
                            tx_pid_i   <= PID_DATA0;
                            tx_crc_i   <= '1';
                            txs        <= X_START;
                        end if;
                    end if;

                when PID_DATA0 | PID_DATA1 =>
                    if for_us = '1' then
                        if cur_endp = x"0" then
                            if crc_rx = (not crc_pair) then
                                tx_pid_i  <= PID_ACK;
                                tx_crc_i  <= '0';
                                wptr      <= (others => '0');
                                rptr      <= (others => '0');
                                pf_pend   <= '0';
                                fetch_rem <= (others => '0');
                                txs       <= X_START;
                                if cur_pid = PID_SETUP and pay_cnt = 8 then
                                    setup_ready <= '1';
                                    setup_cnt   <= setup_cnt + 1;
                                elsif ctl = C_STATUS_OUT then
                                    ctl <= C_IDLE;
                                end if;
                            end if;
                        elsif cur_endp = EP_AUDIO then
                            if crc_rx = (not crc_pair) then
                                audio_done <= '1';
                            else
                                audio_drop <= '1';
                            end if;
                        end if;
                    end if;

                when PID_ACK =>
                    -- The host took the last chunk.
                    if need_ack = '1' then
                        need_ack   <= '0';
                        ep0_toggle <= not ep0_toggle;
                        in_addr <= in_addr + chunk_len;
                        in_rem  <= in_rem - chunk_len;
                        case ctl is
                            when C_IN_DATA =>
                                if in_rem = chunk_len then
                                    if in_zlp = '1' then
                                        in_zlp <= '0';   -- one more, empty
                                    else
                                        ctl <= C_STATUS_OUT;
                                    end if;
                                end if;
                            when C_STATUS_IN =>
                                -- A pending SET_ADDRESS only takes effect once
                                -- the host has seen the status packet.
                                if addr_pending = '1' then
                                    dev_addr     <= new_addr;
                                    addr_pending <= '0';
                                end if;
                                ctl <= C_IDLE;
                            when others =>
                                null;
                        end case;
                    end if;

                when others =>
                    null;
                end case;
            end if;

            --------------------------------------------------------
            -- Setup request decode
            --------------------------------------------------------
            if setup_ready = '1' then
                want   := unsigned(wLengthH) & unsigned(wLengthL);
                len    := (others => '0');
                ok     := false;
                in_rom <= '0';
                in_zlp <= '0';

                if bmRequestType(6 downto 5) = "00" then   -- standard request
                    case bRequest is

                        when x"06" =>                      -- GET_DESCRIPTOR
                            in_rom <= '1';
                            case wValueH is
                                when x"01" =>
                                    in_addr <= to_unsigned(DEVICE_OFF, DESC_ADDR_BITS);
                                    len     := to_unsigned(DEVICE_LEN, 16);
                                    ok      := true;
                                when x"02" =>
                                    in_addr <= to_unsigned(CONFIG_OFF, DESC_ADDR_BITS);
                                    len     := to_unsigned(CONFIG_LEN, 16);
                                    ok      := true;
                                when x"03" =>
                                    case wValueL is
                                        when x"00" =>
                                            in_addr <= to_unsigned(STRING0_OFF, DESC_ADDR_BITS);
                                            len     := to_unsigned(STRING0_LEN, 16);
                                            ok      := true;
                                        when x"01" =>
                                            in_addr <= to_unsigned(STRING1_OFF, DESC_ADDR_BITS);
                                            len     := to_unsigned(STRING1_LEN, 16);
                                            ok      := true;
                                        when x"02" =>
                                            in_addr <= to_unsigned(STRING2_OFF, DESC_ADDR_BITS);
                                            len     := to_unsigned(STRING2_LEN, 16);
                                            ok      := true;
                                        when others =>
                                            null;
                                    end case;
                                when others =>
                                    null;
                            end case;

                        when x"05" =>                      -- SET_ADDRESS
                            new_addr     <= wValueL(6 downto 0);
                            addr_pending <= '1';
                            ok := true;

                        when x"09" =>                      -- SET_CONFIGURATION
                            cfg_val <= wValueL;
                            ok := true;

                        when x"08" =>                      -- GET_CONFIGURATION
                            imm <= x"0000" & cfg_val;
                            len := to_unsigned(1, 16);
                            ok  := true;

                        when x"00" =>                      -- GET_STATUS
                            imm <= x"000000";
                            len := to_unsigned(2, 16);
                            ok  := true;

                        when x"0A" =>                      -- GET_INTERFACE
                            imm <= x"0000" & alt_set;
                            len := to_unsigned(1, 16);
                            ok  := true;

                        when x"0B" =>                      -- SET_INTERFACE
                            alt_set <= wValueL;
                            ok := true;

                        when x"01" | x"03" =>              -- CLEAR/SET_FEATURE
                            ok := true;

                        when others =>
                            null;
                    end case;
                end if;

                if not ok then
                    ctl <= C_STALL;
                elsif len = 0 or want = 0 then
                    -- Nothing to send: straight to the status stage.
                    in_rem <= (others => '0');
                    ctl    <= C_STATUS_IN;
                else
                    if want < len then
                        len := want;
                    end if;
                    in_rem <= len;
                    -- A transfer ends on a short packet.  If the descriptor is
                    -- shorter than asked for but happens to be an exact
                    -- multiple of the packet size, an empty packet has to
                    -- follow or the host keeps waiting.
                    if len < want and len(5 downto 0) = "000000" then
                        in_zlp <= '1';
                    end if;
                    ctl <= C_IN_DATA;
                end if;
            end if;

            --------------------------------------------------------
            -- Transmit sequencer
            --------------------------------------------------------
            case txs is
                when X_IDLE =>
                    tx_req_i <= '0';

                when X_START =>
                    -- Do not start until the buffer is far enough ahead to
                    -- survive the PHY taking bytes on consecutive clocks.
                    -- fetch_rem = 0 covers handshakes and short replies, where
                    -- there is nothing more to wait for.
                    if tx_busy = '0' and (pf_level >= 3 or fetch_rem = 0) then
                        tx_req_i <= '1';
                        tx_cnt   <= tx_cnt + 1;
                        txs      <= X_RUN;
                    end if;

                when X_RUN =>
                    tx_req_i <= '0';
                    if tx_done = '1' then
                        txs <= X_IDLE;
                    end if;
            end case;

            --------------------------------------------------------
            -- Prefetch engine.  One byte is read per clock while there is
            -- room, which keeps the buffer level constant once the packet is
            -- under way, since the PHY can take at most one byte per clock.
            --------------------------------------------------------
            pf_pend <= '0';
            if pf_pend = '1' then
                pf(to_integer(wptr(1 downto 0))) <= rom_out;
                wptr <= wptr + 1;
            end if;

            if fetch_rem > 0
               and (pf_level + ("00" & pf_pend)) < 4 then
                fetch_addr <= fetch_addr + 1;
                fetch_rem  <= fetch_rem - 1;
                fetch_imm  <= x"00" & fetch_imm(23 downto 8);
                pf_pend    <= '1';
            end if;

            if tx_ack = '1' then
                rptr <= rptr + 1;
            end if;

            if rst = '1' then
                ctl      <= C_IDLE;
                txs      <= X_IDLE;
                dev_addr <= (others => '0');
                cfg_val  <= (others => '0');
                alt_set  <= (others => '0');
                tx_req_i <= '0';
                need_ack <= '0';
            end if;

        end if;
    end process;

end Behavioral;
