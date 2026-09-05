library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- The USB device: PHY register setup, the ULPI master and the SIE, wired
-- together and clocked by the PHY.
--
-- The only PHY configuration needed for a full-speed device is two register
-- writes.  OTG control has DpPulldown and DmPulldown set out of reset because
-- the default role is host; leaving them set would put the PHY's pull-downs on
-- the bus alongside the hub's and stop the line ever reading J.  Function
-- control then picks the full-speed transceiver and, with TermSelect, connects
-- the 1.5k pull-up on D+ -- which is the moment the host sees the device
-- appear, so it is deliberately the last thing done.
--
-- The data bus is passed through as separate in/out/enable rather than an
-- inout, so that whatever instantiates this owns the tri-state and can take
-- the bus for its own connectivity test.

entity usb_device is
    Generic (
        -- How long to hold the USB pull-up off before attaching, in ULPI
        -- clocks.  20 ms on hardware, comfortably past the 2.5 us a host
        -- needs to call it a disconnect; simulation shortens it.
        DETACH_CYCLES : natural := 1_200_000
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
        phy_ready  : out STD_LOGIC;   -- the two setup writes have gone out
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

        -- Rate to report to the host, 10.14 samples per frame.
        fb_value : in unsigned(23 downto 0)
    );
end usb_device;

architecture Behavioral of usb_device is

    signal reg_addr  : STD_LOGIC_VECTOR(5 downto 0) := (others => '0');
    signal reg_wdata : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal reg_rd    : STD_LOGIC := '0';
    signal reg_wr    : STD_LOGIC := '0';
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
            linestate   => ls,
            tx_req      => tx_req,
            tx_pid      => tx_pid,
            tx_crc      => tx_crc,
            tx_data     => tx_data,
            tx_valid    => tx_valid,
            tx_ack      => tx_ack,
            tx_done     => tx_done,
            tx_busy     => busy,
            usb_reset   => usb_reset,
            configured  => configured,
            streaming   => streaming,
            dev_addr_o  => dev_addr,
            sof         => sof,
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
            reg_rd <= '0';
            reg_wr <= '0';

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
                        reg_addr  <= PROG(to_integer(step))(13 downto 8);
                        reg_wdata <= PROG(to_integer(step))(7 downto 0);
                        if PROG(to_integer(step))(15) = '1' then
                            reg_wr <= '1';
                        else
                            reg_rd <= '1';
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

    phy_ready <= '1' when ist = I_DONE else '0';
    init_step <= std_logic_vector(step);

end Behavioral;
