library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- The USB device: PHY register setup, the ULPI master and the SIE, wired
-- together and clocked by the PHY.
--
-- The only PHY configuration needed to attach is two register writes.  OTG
-- control has DpPulldown and DmPulldown set out of reset because the default
-- role is host; leaving them set would put the PHY's pull-downs on the bus
-- alongside the hub's and stop the line ever reading J.  Function control then
-- picks the full-speed transceiver and, with TermSelect, connects the 1.5k
-- pull-up on D+ -- which is the moment the host sees the device appear, so it
-- is deliberately the last thing done.
--
-- Everything then attaches at full speed, because that is the only way to be
-- seen at all, and negotiates up.  When the host resets the bus, the device
-- answers with a chirp K; if the host chirps back, both switch to high speed.
-- The register settings for each step come from the USB3300 datasheet's
-- "DP/DM termination vs. signaling mode" table:
--
--     peripheral full speed   XcvrSelect 01, TermSelect 1, OpMode 00  -> 0x45
--     peripheral chirp        XcvrSelect 00, TermSelect 1, OpMode 10  -> 0x54
--     listening for the host  XcvrSelect 00, TermSelect 1, OpMode 00  -> 0x44
--     peripheral high speed   XcvrSelect 00, TermSelect 0, OpMode 00  -> 0x40
--
-- OpMode 10 turns off bit stuffing and NRZI encoding, so transmitting zeroes
-- puts a raw K on the wire.  The datasheet warns that OpMode must not be
-- changed until the transmitter has drained, or the tail of the chirp comes
-- out bit-stuffed, hence the settling wait after the chirp ends.
--
-- High speed is needed here, not merely nice: 384 kHz stereo at four bytes a
-- sample is 3.07 MB/s and a full-speed frame carries at most 1.02 MB/s.  If
-- the host does not chirp back the device stays at full speed and its one
-- streaming format is simply unusable, which is what the device qualifier
-- descriptor tells the host to expect.
--
-- The data bus is passed through as separate in/out/enable rather than an
-- inout, so that whatever instantiates this owns the tri-state and can take
-- the bus for its own connectivity test.

entity usb_device is
    Generic (
        -- How long to hold the USB pull-up off before attaching, in ULPI
        -- clocks.  20 ms on hardware, comfortably past the 2.5 us a host
        -- needs to call it a disconnect; simulation shortens it.
        DETACH_CYCLES : natural := 1_200_000;
        -- Speed negotiation timings, in ULPI clocks at 60 MHz.  Generics so
        -- that simulation can run the handshake in microseconds instead of
        -- milliseconds; the defaults are the real ones.
        CHIRP_CYCLES  : natural := 120_000;   -- 2 ms of chirp K, spec is 1-7
        LISTEN_CYCLES : natural := 180_000;   -- 3 ms to hear the host out
        STABLE_CYCLES : natural := 1_200;     -- 20 us of one host chirp state
        NO_SOF_CYCLES : natural := 180_000    -- 3 ms without a microframe
    );
    Port (
        clk : in STD_LOGIC;   -- 60 MHz, from the PHY
        rst : in STD_LOGIC;

        d_in     : in  STD_LOGIC_VECTOR(7 downto 0);
        d_out    : out STD_LOGIC_VECTOR(7 downto 0);
        d_oe     : out STD_LOGIC;
        ulpi_dir : in  STD_LOGIC;
        ulpi_nxt : in  STD_LOGIC;
        ulpi_stp : out STD_LOGIC;

        -- Status, all in this clock domain.
        phy_ready  : out STD_LOGIC;   -- the setup sequence has completed
        -- High once the high-speed handshake has succeeded.
        speed_hs   : out STD_LOGIC;
        -- Counts completed chirp attempts, for the trace.
        chirps     : out unsigned(7 downto 0);
        phy_id_ok  : out STD_LOGIC;   -- vendor id read back as SMSC
        -- The raw vendor id byte and how far the setup sequence got, so a PHY
        -- that answers with the wrong value can be told from one that never
        -- answers at all.
        phy_vid    : out STD_LOGIC_VECTOR(7 downto 0);
        phy_pid    : out STD_LOGIC_VECTOR(7 downto 0);
        -- Scratch register walk: 0xFF, 0x55 and 0xAA as they came back.
        scr_ff     : out STD_LOGIC_VECTOR(7 downto 0);
        scr_55     : out STD_LOGIC_VECTOR(7 downto 0);
        scr_aa     : out STD_LOGIC_VECTOR(7 downto 0);
        reg_func   : out STD_LOGIC_VECTOR(7 downto 0);
        reg_otg    : out STD_LOGIC_VECTOR(7 downto 0);
        vbus       : out STD_LOGIC_VECTOR(1 downto 0);
        init_step  : out STD_LOGIC_VECTOR(3 downto 0);
        usb_reset  : out STD_LOGIC;
        configured : out STD_LOGIC;
        streaming  : out STD_LOGIC;
        dev_addr   : out STD_LOGIC_VECTOR(6 downto 0);
        sof        : out STD_LOGIC;
        frame_no   : out STD_LOGIC_VECTOR(10 downto 0);
        linestate  : out STD_LOGIC_VECTOR(1 downto 0);

        -- Audio payload from the isochronous OUT endpoint.
        audio_data  : out STD_LOGIC_VECTOR(7 downto 0);
        audio_valid : out STD_LOGIC;
        audio_done  : out STD_LOGIC;
        audio_drop  : out STD_LOGIC;
        stat_setup  : out unsigned(7 downto 0);
        stat_tx     : out unsigned(7 downto 0);

        -- Rate to report to the host, 16.16 samples per microframe.
        fb_value : in unsigned(31 downto 0)
    );
end usb_device;

architecture Behavioral of usb_device is

    signal reg_addr  : STD_LOGIC_VECTOR(5 downto 0);
    signal reg_wdata : STD_LOGIC_VECTOR(7 downto 0);
    signal reg_rd    : STD_LOGIC;
    signal reg_wr    : STD_LOGIC;

    -- The setup sequence owns the register interface until it finishes, and
    -- the speed negotiator owns it afterwards.  They never overlap: the host
    -- cannot reset a device that has not attached yet, and attaching is the
    -- last thing the setup sequence does.
    signal init_addr  : STD_LOGIC_VECTOR(5 downto 0) := (others => '0');
    signal init_wdata : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal init_rd    : STD_LOGIC := '0';
    signal init_wr    : STD_LOGIC := '0';
    signal hs_addr    : STD_LOGIC_VECTOR(5 downto 0) := (others => '0');
    signal hs_wdata   : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal hs_wr      : STD_LOGIC := '0';
    signal init_done  : STD_LOGIC;
    signal reg_rdata : STD_LOGIC_VECTOR(7 downto 0);
    signal reg_done  : STD_LOGIC;
    signal reg_abort : STD_LOGIC;
    signal busy      : STD_LOGIC;

    signal rx_active, rx_valid, rx_error : STD_LOGIC;
    signal rx_data : STD_LOGIC_VECTOR(7 downto 0);
    signal ls      : STD_LOGIC_VECTOR(1 downto 0);

    signal tx_req, tx_crc, tx_valid, tx_ack, tx_done : STD_LOGIC;
    signal tx_pid  : STD_LOGIC_VECTOR(3 downto 0);
    signal tx_data : STD_LOGIC_VECTOR(7 downto 0);

    -- The SIE's side of the transmitter, muxed away while the chirp is out.
    signal sie_tx_req, sie_tx_crc, sie_tx_valid : STD_LOGIC;
    signal sie_tx_pid  : STD_LOGIC_VECTOR(3 downto 0);
    signal sie_tx_data : STD_LOGIC_VECTOR(7 downto 0);

    signal sof_i : STD_LOGIC;

    ------------------------------------------------------------------
    -- Speed negotiation
    ------------------------------------------------------------------
    -- All at 60 MHz.  The chirp itself must last between 1 and 7 ms; the host
    -- answers with K and J each lasting 40 to 60 us, and the device needs to
    -- see three K-J pairs.  Requiring each to hold for 20 us rejects anything
    -- that is not a chirp without being fussy about the host's timing.
    constant T_SE0    : natural := 6_000;   -- 100 us, well past a packet gap
    constant T_SETTLE : natural := 600;     -- 10 us for the transmitter
    constant T_CHIRP  : natural := CHIRP_CYCLES;
    constant T_LISTEN : natural := LISTEN_CYCLES;
    constant T_STABLE : natural := STABLE_CYCLES;
    constant T_NO_SOF : natural := NO_SOF_CYCLES;

    type hs_t is (H_FS, H_WCHIRP, H_CHIRP, H_STOP, H_SETTLE, H_WLISTEN,
                  H_LISTEN, H_WHS, H_HS, H_WFS);
    signal hs : hs_t := H_FS;

    signal hs_timer : unsigned(17 downto 0) := (others => '0');
    signal hs_hold  : unsigned(11 downto 0) := (others => '0');
    signal hs_last  : STD_LOGIC_VECTOR(1 downto 0) := "01";
    signal hs_pairs : unsigned(3 downto 0) := (others => '0');
    signal hs_cnt   : unsigned(7 downto 0) := (others => '0');
    signal chirping    : STD_LOGIC := '0';
    signal chirp_req   : STD_LOGIC := '0';
    signal chirp_valid : STD_LOGIC := '0';
    signal bus_reset   : STD_LOGIC := '0';
    -- One register write is outstanding at a time.  Without this the write
    -- gets issued a second time on the cycle its own completion arrives,
    -- because the bus has already gone idle by then.
    signal hs_issued   : STD_LOGIC := '0';

    -- Identify the part, prove every wire of the data bus, then configure it
    -- and read the configuration back.
    --
    -- The scratch register at 0x16 exists for exactly this: it is read/write
    -- with no effect on the PHY, so walking 0xFF, 0x55 and 0xAA through it
    -- tests all eight data lines in both directions against the far end of the
    -- link.  The FPGA driving its own pins and reading them back cannot do
    -- that -- a wire that never reaches the PHY passes that test and fails
    -- this one.  Product id low is read for the same reason: 0x07 is the only
    -- identifying constant here with bit 0 set.
    --
    -- The sequence deliberately detaches before it attaches: it writes
    -- TermSelect = 0, waits, then writes it back.  A PHY reset does not do
    -- this, because 0x45 -- pull-up on -- is the reset value of Function
    -- Control, so a part coming out of reset is already presenting itself to
    -- the host.  Without an explicit disconnect a host that has given up on
    -- the port never sees a fresh connect and never tries again.
    --
    -- Encoding: bit 15 write, bit 14 delay, bits 13..8 address, bits 7..0
    -- write data.
    type prog_t is array (0 to 13) of STD_LOGIC_VECTOR(15 downto 0);
    constant PROG : prog_t := (
        0  => x"0000",  -- read  vendor id low,    expect 0x24
        1  => x"0200",  -- read  product id low,   expect 0x07
        2  => x"96FF",  -- write scratch        <= 0xFF
        3  => x"1600",  -- read  scratch,          expect 0xFF
        4  => x"9655",  -- write scratch        <= 0x55
        5  => x"1600",  -- read  scratch,          expect 0x55
        6  => x"96AA",  -- write scratch        <= 0xAA
        7  => x"1600",  -- read  scratch,          expect 0xAA
        -- OTG control: clear DpPulldown/DmPulldown.  They default set for
        -- host mode and would fight the host's own pull-downs.
        8  => x"8A00",  -- write otg control      <= 0x00
        -- Full-speed transceiver, pull-up off: detached.
        9  => x"8441",  -- write function control <= 0x41
        10 => x"4000",  -- wait, long enough for the host to see the gap
        -- Function control: XcvrSelect = 01 (full speed), TermSelect = 1
        -- (connect the 1.5k pull-up on D+, i.e. attach), OpMode = 00,
        -- SuspendM = 1 (keep the PHY and its clock running).
        11 => x"8445",  -- write function control <= 0x45
        12 => x"0400",  -- read  function control, expect 0x45
        13 => x"0A00"   -- read  otg control,      expect 0x00
    );

    type ist_t is (I_SETTLE, I_ISSUE, I_BUSY, I_DELAY, I_DONE);
    signal ist    : ist_t := I_SETTLE;
    signal step   : unsigned(3 downto 0) := (others => '0');
    signal settle : unsigned(15 downto 0) := (others => '0');
    signal wait_cnt : unsigned(20 downto 0) := (others => '0');

begin

    linestate <= ls;

    bus_master : entity work.ulpi
        port map (
            clk       => clk,
            rst       => rst,
            d_in      => d_in,
            d_out     => d_out,
            d_oe      => d_oe,
            ulpi_dir  => ulpi_dir,
            ulpi_nxt  => ulpi_nxt,
            ulpi_stp  => ulpi_stp,
            reg_addr  => reg_addr,
            reg_wdata => reg_wdata,
            reg_rd    => reg_rd,
            reg_wr    => reg_wr,
            reg_rdata => reg_rdata,
            reg_done  => reg_done,
            reg_abort => reg_abort,
            busy      => busy,
            tx_req    => tx_req,
            tx_pid    => tx_pid,
            tx_crc    => tx_crc,
            tx_data   => tx_data,
            tx_valid  => tx_valid,
            tx_ack    => tx_ack,
            tx_done   => tx_done,
            rx_active => rx_active,
            rx_valid  => rx_valid,
            rx_data   => rx_data,
            rx_error  => rx_error,
            linestate => ls,
            vbus      => vbus
        );

    sie : entity work.usb_sie
        port map (
            clk         => clk,
            rst         => rst,
            rx_active   => rx_active,
            rx_valid    => rx_valid,
            rx_data     => rx_data,
            rx_error    => rx_error,
            bus_reset   => bus_reset,
            tx_req      => sie_tx_req,
            tx_pid      => sie_tx_pid,
            tx_crc      => sie_tx_crc,
            tx_data     => sie_tx_data,
            tx_valid    => sie_tx_valid,
            tx_ack      => tx_ack,
            tx_done     => tx_done,
            tx_busy     => busy,
            usb_reset   => usb_reset,
            configured  => configured,
            streaming   => streaming,
            dev_addr_o  => dev_addr,
            sof         => sof_i,
            frame_no    => frame_no,
            audio_data  => audio_data,
            audio_valid => audio_valid,
            audio_done  => audio_done,
            audio_drop  => audio_drop,
            stat_setup  => stat_setup,
            stat_tx     => stat_tx,
            fb_value    => fb_value
        );

    ------------------------------------------------------------------
    -- PHY setup
    ------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            init_rd <= '0';
            init_wr <= '0';

            case ist is

                when I_SETTLE =>
                    -- The PHY needs its PLL locked before it will answer.
                    if settle = 60000 then      -- 1 ms at 60 MHz
                        ist <= I_ISSUE;
                    else
                        settle <= settle + 1;
                    end if;

                when I_ISSUE =>
                    if PROG(to_integer(step))(14) = '1' then
                        wait_cnt <= (others => '0');
                        ist      <= I_DELAY;
                    elsif busy = '0' then
                        init_addr  <= PROG(to_integer(step))(13 downto 8);
                        init_wdata <= PROG(to_integer(step))(7 downto 0);
                        if PROG(to_integer(step))(15) = '1' then
                            init_wr <= '1';
                        else
                            init_rd <= '1';
                        end if;
                        ist <= I_BUSY;
                    end if;

                when I_BUSY =>
                    if reg_abort = '1' then
                        -- The PHY pre-empted the transfer, which it does
                        -- whenever the USB lines change -- and clearing the
                        -- pull-downs a moment ago changes them.  Reissue the
                        -- same step; a repeated write is harmless.
                        ist <= I_ISSUE;
                    elsif reg_done = '1' then
                        case to_integer(step) is
                            when 0 =>
                                phy_vid <= reg_rdata;
                                if reg_rdata = x"24" then
                                    phy_id_ok <= '1';
                                else
                                    phy_id_ok <= '0';
                                end if;
                            when 1  => phy_pid  <= reg_rdata;
                            when 3  => scr_ff   <= reg_rdata;
                            when 5  => scr_55   <= reg_rdata;
                            when 7  => scr_aa   <= reg_rdata;
                            when 12 => reg_func <= reg_rdata;
                            when 13 => reg_otg  <= reg_rdata;
                            when others => null;
                        end case;
                        if step = PROG'high then
                            ist <= I_DONE;
                        else
                            step <= step + 1;
                            ist  <= I_ISSUE;
                        end if;
                    end if;

                when I_DELAY =>
                    if wait_cnt = DETACH_CYCLES then
                        if step = PROG'high then
                            ist <= I_DONE;
                        else
                            step <= step + 1;
                            ist  <= I_ISSUE;
                        end if;
                    else
                        wait_cnt <= wait_cnt + 1;
                    end if;

                when I_DONE =>
                    null;
            end case;

            if rst = '1' then
                ist       <= I_SETTLE;
                settle    <= (others => '0');
                step      <= (others => '0');
                phy_id_ok <= '0';
                phy_vid   <= (others => '0');
            end if;
        end if;
    end process;

    init_done <= '1' when ist = I_DONE else '0';
    phy_ready <= init_done;
    init_step <= std_logic_vector(step);
    speed_hs  <= '1' when hs = H_HS else '0';
    chirps    <= hs_cnt;
    sof       <= sof_i;

    ------------------------------------------------------------------
    -- Bus arbitration.  The setup sequence goes first and hands over for
    -- good; the chirp only ever runs long after it has finished.
    ------------------------------------------------------------------
    reg_addr  <= hs_addr  when init_done = '1' else init_addr;
    reg_wdata <= hs_wdata when init_done = '1' else init_wdata;
    reg_wr    <= hs_wr    when init_done = '1' else init_wr;
    reg_rd    <= '0'      when init_done = '1' else init_rd;

    -- While chirping, the transmitter belongs to the negotiator.  Nothing is
    -- lost by cutting the SIE off: a bus reset discards whatever was in
    -- flight anyway.
    tx_req   <= chirp_req   when chirping = '1' else sie_tx_req;
    tx_pid   <= "0000"      when chirping = '1' else sie_tx_pid;
    tx_crc   <= '0'         when chirping = '1' else sie_tx_crc;
    tx_data  <= x"00"       when chirping = '1' else sie_tx_data;
    tx_valid <= chirp_valid when chirping = '1' else sie_tx_valid;

    ------------------------------------------------------------------
    -- Speed negotiation
    ------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            hs_wr     <= '0';
            chirp_req <= '0';
            bus_reset <= '0';

            case hs is

                -- Attached at full speed, watching for the host to reset the
                -- bus.  SE0 for longer than any inter-packet gap is a reset.
                when H_FS =>
                    chirping <= '0';
                    if ls = "00" then
                        if hs_timer = T_SE0 then
                            hs_timer  <= (others => '0');
                            bus_reset <= '1';
                            hs_issued <= '0';
                            hs        <= H_WCHIRP;
                        else
                            hs_timer <= hs_timer + 1;
                        end if;
                    else
                        hs_timer <= (others => '0');
                    end if;

                -- Switch the transceiver to high speed with the full-speed
                -- termination still on, and turn off bit stuffing so that
                -- transmitting zeroes puts a raw K on the wire.
                when H_WCHIRP =>
                    if reg_done = '1' then
                        hs_timer    <= (others => '0');
                        chirping    <= '1';
                        chirp_valid <= '1';
                        chirp_req   <= '1';
                        hs_issued <= '0';
                        hs        <= H_CHIRP;
                    elsif hs_issued = '0' and busy = '0' then
                        hs_addr   <= "000100";   -- function control
                        hs_wdata  <= x"54";
                        hs_wr     <= '1';
                        hs_issued <= '1';
                    elsif reg_abort = '1' then
                        hs_issued <= '0';
                    end if;
                    if reg_done = '1' then
                        hs_timer    <= (others => '0');
                        chirping    <= '1';
                        chirp_valid <= '1';
                        chirp_req   <= '1';
                        hs          <= H_CHIRP;
                    end if;

                -- Chirp K.  tx_valid stays high with zero data for the whole
                -- 2 ms; the PHY takes bytes at whatever rate it likes and
                -- they are all the same.
                when H_CHIRP =>
                    if hs_timer = T_CHIRP then
                        hs_timer <= (others => '0');
                        hs       <= H_STOP;
                    else
                        hs_timer <= hs_timer + 1;
                    end if;

                -- Dropping tx_valid with no CRC wanted ends the packet with
                -- STP.
                when H_STOP =>
                    chirp_valid <= '0';
                    if tx_done = '1' then
                        hs_timer <= (others => '0');
                        hs       <= H_SETTLE;
                    end if;

                -- The datasheet is explicit that OpMode must not change until
                -- the transmit pipeline has drained.
                when H_SETTLE =>
                    chirping <= '0';
                    if hs_timer = T_SETTLE then
                        hs_timer  <= (others => '0');
                        hs_issued <= '0';
                        hs        <= H_WLISTEN;
                    else
                        hs_timer <= hs_timer + 1;
                    end if;

                when H_WLISTEN =>
                    if reg_done = '1' then
                        hs_timer <= (others => '0');
                        hs_hold  <= (others => '0');
                        hs_pairs <= (others => '0');
                        hs_last  <= "01";
                        hs_issued <= '0';
                        hs        <= H_LISTEN;
                    elsif hs_issued = '0' and busy = '0' then
                        hs_addr   <= "000100";   -- function control
                        hs_wdata  <= x"44";
                        hs_wr     <= '1';
                        hs_issued <= '1';
                    elsif reg_abort = '1' then
                        hs_issued <= '0';
                    end if;
                    if reg_done = '1' then
                        hs_timer <= (others => '0');
                        hs_hold  <= (others => '0');
                        hs_pairs <= (others => '0');
                        hs_last  <= "01";
                        hs       <= H_LISTEN;
                    end if;

                -- Count the host's alternating chirps.  Each has to hold for
                -- 20 us before it counts, which rejects the transitions
                -- between them and any stray line activity.
                when H_LISTEN =>
                    if ls = hs_last then
                        hs_hold <= (others => '0');
                    elsif ls = "01" or ls = "10" then
                        if hs_hold = T_STABLE then
                            hs_hold <= (others => '0');
                            hs_last <= ls;
                            hs_pairs <= hs_pairs + 1;
                        else
                            hs_hold <= hs_hold + 1;
                        end if;
                    else
                        hs_hold <= (others => '0');
                    end if;

                    -- Six alternations is three K-J pairs, the minimum the
                    -- specification asks a device to recognise.
                    if hs_pairs = 6 then
                        hs_timer  <= (others => '0');
                        hs_issued <= '0';
                        hs        <= H_WHS;
                    elsif hs_timer = T_LISTEN then
                        hs_timer  <= (others => '0');
                        hs_issued <= '0';
                        hs        <= H_WFS;
                    else
                        hs_timer <= hs_timer + 1;
                    end if;

                -- The host chirped back: drop the full-speed pull-up and take
                -- the high-speed termination.
                when H_WHS =>
                    if reg_done = '1' then
                        hs_cnt   <= hs_cnt + 1;
                        hs_timer <= (others => '0');
                        hs_issued <= '0';
                        hs        <= H_HS;
                    elsif hs_issued = '0' and busy = '0' then
                        hs_addr   <= "000100";   -- function control
                        hs_wdata  <= x"40";
                        hs_wr     <= '1';
                        hs_issued <= '1';
                    elsif reg_abort = '1' then
                        hs_issued <= '0';
                    end if;
                    if reg_done = '1' then
                        hs_cnt   <= hs_cnt + 1;
                        hs_timer <= (others => '0');
                        hs       <= H_HS;
                    end if;

                -- Running at high speed.  A microframe arrives every 125 us,
                -- so a long gap means the host has reset or suspended the bus;
                -- either way, going back to full-speed termination is what
                -- lets the handshake start again.
                when H_HS =>
                    if sof_i = '1' then
                        hs_timer <= (others => '0');
                    elsif hs_timer = T_NO_SOF then
                        hs_timer  <= (others => '0');
                        bus_reset <= '1';
                        hs_issued <= '0';
                        hs        <= H_WFS;
                    else
                        hs_timer <= hs_timer + 1;
                    end if;

                when H_WFS =>
                    if reg_done = '1' then
                        hs_timer <= (others => '0');
                        hs_issued <= '0';
                        hs        <= H_FS;
                    elsif hs_issued = '0' and busy = '0' then
                        hs_addr   <= "000100";   -- function control
                        hs_wdata  <= x"45";
                        hs_wr     <= '1';
                        hs_issued <= '1';
                    elsif reg_abort = '1' then
                        hs_issued <= '0';
                    end if;
                    if reg_done = '1' then
                        hs_timer <= (others => '0');
                        hs       <= H_FS;
                    end if;

            end case;

            -- A pre-empted register write needs no special handling: each
            -- state above simply reissues whenever the bus is free again, and
            -- only leaves on reg_done.  The PHY does pre-empt often here,
            -- since it reports every line state change during a reset.

            if rst = '1' or init_done = '0' then
                hs          <= H_FS;
                hs_timer    <= (others => '0');
                chirping    <= '0';
                chirp_valid <= '0';
                hs_issued   <= '0';
            end if;
        end if;
    end process;

end Behavioral;
