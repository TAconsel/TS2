library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.TEXTIO.all;

library work;
use work.usb_desc.all;

-- Testbench for usb_device: a ULPI PHY and a USB host, enough of each to walk
-- the device through a real enumeration and an audio transfer.
--
-- The PHY half obeys the same handshake the SMSC part does -- DIR to take the
-- bus, NXT to accept a byte, a turnaround cycle on every direction change --
-- and deliberately spaces bytes 40 clocks apart, which is what full speed
-- actually looks like on a 60 MHz ULPI bus.  Feeding bytes faster than that
-- would hide the descriptor ROM's read latency.
--
-- The host half sends real tokens and data packets with correct CRC5 and
-- CRC16, and checks what comes back, so a wrong length or a stuck data toggle
-- shows up here rather than as a device that "almost" enumerates.

entity tb_usb_device is
end tb_usb_device;

architecture sim of tb_usb_device is

    constant PERIOD    : time    := 16.667 ns;   -- 60 MHz
    -- One full-speed byte is 8 bits at 12 Mbit/s, which is 40 ULPI clocks.
    constant BYTE_CLKS : natural := 40;

    signal clk : STD_LOGIC := '0';
    signal rst : STD_LOGIC := '1';
    signal running : boolean := true;

    signal ulpi_d   : STD_LOGIC_VECTOR(7 downto 0);
    signal phy_d    : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal phy_oe   : STD_LOGIC := '0';
    signal dir      : STD_LOGIC := '0';
    signal nxt      : STD_LOGIC := '0';
    signal stp      : STD_LOGIC;

    signal d_in  : STD_LOGIC_VECTOR(7 downto 0);
    signal d_out : STD_LOGIC_VECTOR(7 downto 0);
    signal d_oe  : STD_LOGIC;

    signal phy_ready, phy_id_ok, usb_reset, configured, streaming : STD_LOGIC;
    signal phy_vid, phy_pid : STD_LOGIC_VECTOR(7 downto 0);
    signal scr_ff, scr_55, scr_aa : STD_LOGIC_VECTOR(7 downto 0);
    signal reg_func, reg_otg : STD_LOGIC_VECTOR(7 downto 0);
    signal vbus : STD_LOGIC_VECTOR(1 downto 0);
    signal init_step : STD_LOGIC_VECTOR(3 downto 0);
    signal dev_addr  : STD_LOGIC_VECTOR(6 downto 0);
    signal sof       : STD_LOGIC;
    signal frame_no  : STD_LOGIC_VECTOR(10 downto 0);
    signal linestate : STD_LOGIC_VECTOR(1 downto 0);

    signal audio_data  : STD_LOGIC_VECTOR(7 downto 0);
    signal audio_valid : STD_LOGIC;
    signal audio_done  : STD_LOGIC;
    signal audio_drop  : STD_LOGIC;

    signal fb_value : unsigned(23 downto 0) := to_unsigned(48 * 16384, 24);

    -- Audio bytes the device handed on, collected for checking.
    signal audio_count : natural := 0;
    signal audio_last  : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal audio_first : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal done_count  : natural := 0;
    signal drop_count  : natural := 0;


    type byte_arr is array (natural range <>) of STD_LOGIC_VECTOR(7 downto 0);

    -- USB CRC5 over the eleven address/endpoint bits of a token.
    function crc5(d : STD_LOGIC_VECTOR(10 downto 0))
        return STD_LOGIC_VECTOR is
        variable c : STD_LOGIC_VECTOR(4 downto 0) := "11111";
        variable fb : STD_LOGIC;
    begin
        for i in 0 to 10 loop
            fb := d(i) xor c(0);
            c := '0' & c(4 downto 1);
            if fb = '1' then
                c := c xor "10100";
            end if;
        end loop;
        return not c;
    end function;

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

    clk <= (not clk) after PERIOD / 2 when running else '0';

    ulpi_d <= d_out when d_oe = '1' else (others => 'Z');
    ulpi_d <= phy_d when phy_oe = '1' else (others => 'Z');
    d_in   <= ulpi_d;

    dut : entity work.usb_device
        -- 100 us instead of 20 ms: long enough to exercise the delay step,
        -- short enough not to dominate the run.
        generic map (DETACH_CYCLES => 6000)
        port map (
            clk         => clk,
            rst         => rst,
            d_in        => d_in,
            d_out       => d_out,
            d_oe        => d_oe,
            ulpi_dir    => dir,
            ulpi_nxt    => nxt,
            ulpi_stp    => stp,
            phy_ready   => phy_ready,
            phy_id_ok   => phy_id_ok,
            phy_vid     => phy_vid,
            phy_pid     => phy_pid,
            scr_ff      => scr_ff,
            scr_55      => scr_55,
            scr_aa      => scr_aa,
            reg_func    => reg_func,
            reg_otg     => reg_otg,
            vbus        => vbus,
            init_step   => init_step,
            usb_reset   => usb_reset,
            configured  => configured,
            streaming   => streaming,
            dev_addr    => dev_addr,
            sof         => sof,
            frame_no    => frame_no,
            linestate   => linestate,
            audio_data  => audio_data,
            audio_valid => audio_valid,
            audio_done  => audio_done,
            audio_drop  => audio_drop,
            fb_value    => fb_value
        );

    -- Watch the audio side effects.
    monitor : process(clk)
    begin
        if rising_edge(clk) then
            if audio_valid = '1' then
                if audio_count = 0 then
                    audio_first <= audio_data;
                end if;
                audio_last  <= audio_data;
                audio_count <= audio_count + 1;
            end if;
            if audio_done = '1' then
                done_count <= done_count + 1;
            end if;
            if audio_drop = '1' then
                drop_count <= drop_count + 1;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------
    -- PHY and host
    ------------------------------------------------------------------
    main : process

        variable cap     : byte_arr(0 to 271);
        variable cap_n   : natural;
        variable ok      : boolean;

        -- The PHY's register file.  Reads and writes go through here rather
        -- than returning one canned value, so that reading the wrong address,
        -- or returning a byte left over from the previous transfer, shows up
        -- as a wrong value instead of passing by luck.
        variable regs : byte_arr(0 to 63) := (
            16#00# => x"24",   -- vendor id low   (SMSC)
            16#01# => x"04",   -- vendor id high
            16#02# => x"07",   -- product id low  (USB3300)
            16#03# => x"00",   -- product id high
            16#04# => x"45",   -- function control, reset value
            16#0A# => x"06",   -- otg control, both pull-downs set
            others => x"00"
        );

        variable errs : natural := 0;

        procedure note(s : string) is
            variable l : line;
        begin
            write(l, now, right, 10, ns);
            write(l, string'("  "));
            write(l, s);
            writeline(output, l);
        end procedure;

        procedure fail(s : string) is
        begin
            note("FAIL: " & s);
            errs := errs + 1;
        end procedure;

        procedure check(cond : boolean; s : string) is
        begin
            if cond then
                note("ok   " & s);
            else
                fail(s);
            end if;
        end procedure;

        -- Verify the CRC16 on a packet the device transmitted.  Nothing else
        -- in this testbench looks at it, and a wrong transmit CRC is exactly
        -- what a host reports as a protocol error while everything on this
        -- side looks like it is working.
        procedure check_tx_crc(what : string) is
            variable c : STD_LOGIC_VECTOR(15 downto 0) := (others => '1');
        begin
            if cap_n < 3 then
                fail("packet too short to carry a CRC: " & what);
                return;
            end if;
            for i in 1 to cap_n - 3 loop
                c := crc16_byte(c, cap(i));
            end loop;
            if cap(cap_n - 2) /= not c(7 downto 0)
               or cap(cap_n - 1) /= not c(15 downto 8) then
                fail("CRC16 wrong on " & what);
            else
                note("ok   CRC16 correct on " & what);
            end if;
        end procedure;

        procedure tick(n : natural := 1) is
        begin
            for i in 1 to n loop
                wait until rising_edge(clk);
            end loop;
        end procedure;

        -- Deliver bytes to the link exactly as the PHY would: take the bus
        -- with DIR, spend a turnaround cycle, send an RX CMD saying the
        -- receiver is active, then the packet, then an RX CMD clearing it.
        -- With err set, the PHY reports a receive error partway through, the
        -- way it does for a bit stuffing or sync fault on the wire.
        procedure phy_rx(data : byte_arr; ls : STD_LOGIC_VECTOR(1 downto 0);
                         err : boolean := false) is
        begin
            dir    <= '1';
            phy_oe <= '1';
            phy_d  <= x"00";
            tick;                          -- turnaround
            phy_d <= "00" & "01" & "01" & ls;   -- RX CMD, RxActive set
            tick;
            for i in data'range loop
                phy_d <= data(i);
                nxt   <= '1';
                tick;
                nxt   <= '0';
                if err and i = data'low then
                    phy_d <= "00" & "11" & "01" & ls;   -- RxError
                else
                    phy_d <= "00" & "01" & "01" & ls;
                end if;
                tick(BYTE_CLKS - 1);
            end loop;
            phy_d <= "00" & "00" & "01" & ls;   -- RX CMD, RxActive clear
            tick;
            dir    <= '0';
            phy_oe <= '0';
            tick;
        end procedure;

        -- Sit on the bus as the PHY and answer whatever the link asks for.
        -- Register accesses are handled silently; a USB transmit is captured
        -- into cap/cap_n.  Returns ok = false if nothing happened in time.
        procedure service(timeout : natural; got : out boolean) is
            variable cmd  : STD_LOGIC_VECTOR(7 downto 0);
            variable n    : natural := 0;
            variable idle : natural := 0;
            variable stopped : boolean := false;
        begin
            got := false;
            cap_n := 0;
            -- Wait for the link to drive something other than the idle byte.
            loop
                tick;
                exit when d_oe = '1' and d_out /= x"00";
                idle := idle + 1;
                if idle > timeout then
                    return;
                end if;
            end loop;
            cmd := d_out;
            got := true;

            nxt <= '1';
            tick;                       -- first NXT cycle: command taken
            if cmd(7 downto 6) = "10" then
                -- Register write.  The real USB3300 keeps NXT asserted for the
                -- very next cycle as well and takes whatever is on the bus
                -- then as the write data, so the link gets exactly one cycle
                -- to change it.  Modelling that is the whole point: a PHY that
                -- politely waited would hide a link that reacts a cycle late.
                tick;                   -- second NXT cycle: data taken
                regs(to_integer(unsigned(cmd(5 downto 0)))) := d_out;
                nxt <= '0';
            elsif cmd(7 downto 6) = "11" then
                nxt <= '0';
            end if;
            -- For a USB transmit NXT stays asserted into the burst below.

            if cmd(7 downto 6) = "11" then
                -- Register read: turn the bus around, then present the value
                -- for exactly one cycle.
                tick;
                dir    <= '1';
                phy_oe <= '1';
                phy_d  <= x"00";
                tick;                       -- turnaround
                phy_d <= regs(to_integer(unsigned(cmd(5 downto 0))));
                tick;
                dir    <= '0';
                phy_oe <= '0';
                tick;

            elsif cmd(7 downto 6) = "10" then
                -- The data byte has already been taken above; all that is
                -- left is the link's closing STP.
                loop
                    tick;
                    exit when stp = '1';
                end loop;

            else
                -- USB transmit.  The command byte carries the PID.  The real
                -- part fills its own FIFO first: NXT stays asserted for two
                -- more clocks and it takes whatever is on the bus each time,
                -- and only then throttles to one byte per 40 clocks the way
                -- full speed implies.  A model that throttled from the start
                -- would let a source with a cycle of read latency pass.
                cap(0) := cmd;
                n := 1;
                stopped := false;
                for k in 1 to 2 loop
                    tick;
                    if stp = '1' then
                        stopped := true;
                        exit;
                    end if;
                    cap(n) := d_out;
                    n := n + 1;
                end loop;
                nxt <= '0';

                while not stopped loop
                    for i in 1 to BYTE_CLKS loop
                        tick;
                        if stp = '1' then
                            stopped := true;
                            exit;
                        end if;
                    end loop;
                    exit when stopped;
                    cap(n) := d_out;
                    n := n + 1;
                    nxt <= '1';
                    tick;
                    nxt <= '0';
                end loop;
                cap_n := n;
            end if;
        end procedure;

        -- Seize the bus just as the link starts a command, the way the PHY
        -- does whenever the USB line state changes -- which it does the
        -- moment the pull-downs are cleared, so this races the very next
        -- register write.  The link must abandon the transfer and reissue it
        -- rather than waiting for a completion that will never come.
        procedure preempt is
        begin
            loop
                tick;
                exit when d_oe = '1' and d_out /= x"00";
            end loop;
            dir    <= '1';
            phy_oe <= '1';
            phy_d  <= x"00";
            tick;                                   -- turnaround
            phy_d  <= "00" & "00" & "01" & "01";    -- RX CMD, idle J
            tick;
            dir    <= '0';
            phy_oe <= '0';
            tick(4);
        end procedure;

        -- A token packet: PID, then seven address bits, four endpoint bits and
        -- a CRC5, least significant bit first.
        function token(pid : STD_LOGIC_VECTOR(3 downto 0);
                       addr : natural; endp : natural) return byte_arr is
            variable a : STD_LOGIC_VECTOR(6 downto 0) :=
                std_logic_vector(to_unsigned(addr, 7));
            variable e : STD_LOGIC_VECTOR(3 downto 0) :=
                std_logic_vector(to_unsigned(endp, 4));
            variable f : STD_LOGIC_VECTOR(10 downto 0);
            variable c : STD_LOGIC_VECTOR(4 downto 0);
            variable r : byte_arr(0 to 2);
        begin
            f := e & a;
            c := crc5(f);
            r(0) := (not pid) & pid;
            r(1) := e(0) & a;
            r(2) := c & e(3 downto 1);
            return r;
        end function;

        function handshake(pid : STD_LOGIC_VECTOR(3 downto 0)) return byte_arr is
            variable r : byte_arr(0 to 0);
        begin
            r(0) := (not pid) & pid;
            return r;
        end function;

        -- A data packet: PID, payload, CRC16 low then high.
        function data_pkt(pid : STD_LOGIC_VECTOR(3 downto 0);
                          payload : byte_arr) return byte_arr is
            variable r : byte_arr(0 to payload'length + 2);
            variable c : STD_LOGIC_VECTOR(15 downto 0) := (others => '1');
            variable k : natural := 1;
        begin
            r(0) := (not pid) & pid;
            for i in payload'range loop
                r(k) := payload(i);
                c := crc16_byte(c, payload(i));
                k := k + 1;
            end loop;
            r(k)     := not c(7 downto 0);
            r(k + 1) := not c(15 downto 8);
            return r;
        end function;

        function setup_pkt(bmrt, breq : natural;
                           wval, widx, wlen : natural) return byte_arr is
            variable p : byte_arr(0 to 7);
        begin
            p(0) := std_logic_vector(to_unsigned(bmrt, 8));
            p(1) := std_logic_vector(to_unsigned(breq, 8));
            p(2) := std_logic_vector(to_unsigned(wval mod 256, 8));
            p(3) := std_logic_vector(to_unsigned(wval / 256, 8));
            p(4) := std_logic_vector(to_unsigned(widx mod 256, 8));
            p(5) := std_logic_vector(to_unsigned(widx / 256, 8));
            p(6) := std_logic_vector(to_unsigned(wlen mod 256, 8));
            p(7) := std_logic_vector(to_unsigned(wlen / 256, 8));
            return p;
        end function;

        constant IDLE_J : STD_LOGIC_VECTOR(1 downto 0) := "01";
        constant SE0    : STD_LOGIC_VECTOR(1 downto 0) := "00";

        constant PID_OUT   : STD_LOGIC_VECTOR(3 downto 0) := x"1";
        constant PID_IN    : STD_LOGIC_VECTOR(3 downto 0) := x"9";
        constant PID_SOF   : STD_LOGIC_VECTOR(3 downto 0) := x"5";
        constant PID_SETUP : STD_LOGIC_VECTOR(3 downto 0) := x"D";
        constant PID_DATA0 : STD_LOGIC_VECTOR(3 downto 0) := x"3";
        constant PID_DATA1 : STD_LOGIC_VECTOR(3 downto 0) := x"B";
        constant PID_ACK   : STD_LOGIC_VECTOR(3 downto 0) := x"2";

        -- Run one control transfer's data stage: repeat IN tokens until a
        -- short packet arrives, acknowledging each, then the status stage.
        -- rom_off is where in the descriptor ROM the reply should have come
        -- from.  Comparing the whole payload against it, rather than just
        -- counting bytes, is what catches a byte that went out twice because
        -- the source could not keep up with the PHY.
        procedure control_in(addr : natural; expect_len : natural;
                             rom_off : natural;
                             first_byte : out STD_LOGIC_VECTOR(7 downto 0);
                             total : out natural) is
            variable total_v : natural := 0;
            variable fb_v : STD_LOGIC_VECTOR(7 downto 0) := x"00";
            variable payload : natural;
            variable wrong : natural := 0;
        begin
            loop
                phy_rx(token(PID_IN, addr, 0), IDLE_J);
                service(4000, ok);
                if not ok then
                    fail("no response to IN token");
                    exit;
                end if;
                -- cap(0) is the transmit command carrying the PID, cap(1..)
                -- the payload with its CRC16 on the end.
                payload := 0;
                if cap_n >= 3 then
                    payload := cap_n - 3;
                end if;
                if total_v = 0 and payload > 0 then
                    -- cap(0) is the transmit command byte, so the payload
                    -- starts at cap(1).
                    fb_v := cap(1);
                end if;
                for k in 0 to payload - 1 loop
                    if cap(1 + k) /= DESC_ROM(rom_off + total_v + k) then
                        wrong := wrong + 1;
                    end if;
                end loop;
                total_v := total_v + payload;
                check_tx_crc("a control IN data packet");
                phy_rx(handshake(PID_ACK), IDLE_J);
                exit when payload < 64;
                exit when total_v >= expect_len;
            end loop;
            -- Status stage: a zero-length OUT that the device must acknowledge.
            phy_rx(token(PID_OUT, addr, 0), IDLE_J);
            phy_rx(data_pkt(PID_DATA1, byte_arr'(1 to 0 => x"00")), IDLE_J);
            service(4000, ok);
            check(wrong = 0, "descriptor bytes match the ROM exactly, "
                  & integer'image(wrong) & " wrong of "
                  & integer'image(total_v));
            first_byte := fb_v;
            total := total_v;
        end procedure;

        variable first : STD_LOGIC_VECTOR(7 downto 0);
        variable total : natural;
        variable audio : byte_arr(0 to 191);
        variable bad   : byte_arr(0 to 194);
        variable pkts  : natural;

    begin
        note("start");
        tick(5);
        rst <= '0';

        -- The PHY reports line state in every RX CMD; give the link an idle J
        -- to look at before anything else happens.
        phy_rx(byte_arr'(0 => x"00"), IDLE_J);

        -- The PHY setup sequence starts about 1 ms after reset: identify the
        -- part, walk the data bus through the scratch register, then
        -- configure it and read the configuration back.
        for i in 0 to 13 loop
            -- Interrupt the function control write, which is where the real
            -- part does it: clearing the pull-downs one step earlier changes
            -- the line state and the PHY reports it immediately.
            if i = 9 then
                preempt;
            end if;
            -- Step 10 is the detach delay, not a bus transfer.
            next when i = 10;
            service(200000, ok);
            if not ok then
                fail("PHY setup command " & integer'image(i) & " never issued");
            end if;
        end loop;
        tick(10);
        check(phy_ready = '1', "PHY setup sequence completed, reached step "
              & integer'image(to_integer(unsigned(init_step))));
        check(regs(16#04#) = x"45",
              "function control left attached after the detach and re-attach");
        check(phy_id_ok = '1' and phy_vid = x"24", "vendor id read back as SMSC");
        check(phy_pid = x"07", "product id read back as USB3300, got "
              & integer'image(to_integer(unsigned(phy_pid))));
        check(scr_ff = x"FF" and scr_55 = x"55" and scr_aa = x"AA",
              "scratch register walk returned what was written");
        check(reg_func = x"45",
              "function control took 0x45 after the PHY pre-empted the write");
        check(reg_otg = x"00", "otg control took 0x00");

        -- A host reset: SE0 for well over the 100 us the device looks for.
        dir <= '1'; phy_oe <= '1'; phy_d <= x"00";
        tick;
        phy_d <= "00" & "00" & "00" & SE0;
        tick(7000);
        dir <= '0'; phy_oe <= '0';
        tick(10);
        check(dev_addr = "0000000", "address cleared by bus reset");

        phy_rx(byte_arr'(0 => x"00"), IDLE_J);

        ----------------------------------------------------------------
        note("--- GET_DESCRIPTOR(DEVICE) to address 0 ---");
        phy_rx(token(PID_SETUP, 0, 0), IDLE_J);
        phy_rx(data_pkt(PID_DATA0, setup_pkt(16#80#, 16#06#, 16#0100#, 0, 64)),
               IDLE_J);
        service(4000, ok);
        check(ok and cap_n = 1 and cap(0)(3 downto 0) = PID_ACK,
              "setup acknowledged");

        control_in(0, 18, DEVICE_OFF, first, total);
        check(total = 18, "device descriptor is 18 bytes, got "
              & integer'image(total));
        check(first = x"12", "device descriptor starts with bLength 18");

        ----------------------------------------------------------------
        note("--- SET_ADDRESS(7) ---");
        phy_rx(token(PID_SETUP, 0, 0), IDLE_J);
        phy_rx(data_pkt(PID_DATA0, setup_pkt(16#00#, 16#05#, 7, 0, 0)), IDLE_J);
        service(4000, ok);
        check(ok and cap(0)(3 downto 0) = PID_ACK, "SET_ADDRESS acknowledged");
        -- Status stage is an IN with nothing in it.
        phy_rx(token(PID_IN, 0, 0), IDLE_J);
        service(4000, ok);
        check(ok and cap_n = 3, "zero-length status packet returned");
        check_tx_crc("the zero-length status packet");
        check(dev_addr = "0000000", "address not applied before the host ACK");
        phy_rx(handshake(PID_ACK), IDLE_J);
        tick(20);
        check(dev_addr = "0000111", "address 7 applied after the ACK");

        ----------------------------------------------------------------
        note("--- GET_DESCRIPTOR(CONFIG), spans two packets ---");
        phy_rx(token(PID_SETUP, 7, 0), IDLE_J);
        phy_rx(data_pkt(PID_DATA0, setup_pkt(16#80#, 16#06#, 16#0200#, 0, 255)),
               IDLE_J);
        service(4000, ok);
        check(ok and cap(0)(3 downto 0) = PID_ACK, "setup acknowledged");
        control_in(7, CONFIG_LEN, CONFIG_OFF, first, total);
        check(total = CONFIG_LEN, "config descriptor is "
              & integer'image(CONFIG_LEN) & " bytes, got "
              & integer'image(total));
        check(first = x"09", "config descriptor starts with bLength 9");

        ----------------------------------------------------------------
        note("--- SET_CONFIGURATION(1) and SET_INTERFACE(1,1) ---");
        phy_rx(token(PID_SETUP, 7, 0), IDLE_J);
        phy_rx(data_pkt(PID_DATA0, setup_pkt(16#00#, 16#09#, 1, 0, 0)), IDLE_J);
        service(4000, ok);
        phy_rx(token(PID_IN, 7, 0), IDLE_J);
        service(4000, ok);
        phy_rx(handshake(PID_ACK), IDLE_J);
        tick(20);
        check(configured = '1', "device reports configured");

        phy_rx(token(PID_SETUP, 7, 0), IDLE_J);
        phy_rx(data_pkt(PID_DATA0, setup_pkt(16#01#, 16#0B#, 1, 1, 0)), IDLE_J);
        service(4000, ok);
        phy_rx(token(PID_IN, 7, 0), IDLE_J);
        service(4000, ok);
        phy_rx(handshake(PID_ACK), IDLE_J);
        tick(20);
        check(streaming = '1', "streaming interface selected");

        ----------------------------------------------------------------
        note("--- isochronous audio OUT ---");
        for i in audio'range loop
            audio(i) := std_logic_vector(to_unsigned(i mod 256, 8));
        end loop;
        phy_rx(token(PID_SOF, 0, 0), IDLE_J);
        phy_rx(token(PID_OUT, 7, EP_AUDIO_OUT), IDLE_J);
        phy_rx(data_pkt(PID_DATA0, audio), IDLE_J);
        tick(20);
        check(audio_count = 192, "192 audio bytes delivered, got "
              & integer'image(audio_count));
        check(audio_first = x"00" and audio_last = x"BF",
              "audio payload arrived intact with the CRC stripped");
        check(done_count = 1 and drop_count = 0, "packet accepted, none dropped");

        ----------------------------------------------------------------
        note("--- corrupt isochronous packet is dropped, not passed on ---");
        bad := data_pkt(PID_DATA0, audio);
        bad(193) := not bad(193);          -- break the CRC16
        phy_rx(token(PID_OUT, 7, EP_AUDIO_OUT), IDLE_J);
        phy_rx(bad, IDLE_J);
        tick(20);
        check(drop_count = 1, "bad CRC reported as a drop");

        ----------------------------------------------------------------
        note("--- a runt token is ignored ---");
        -- Two bytes where a token needs three.  Without a length check the
        -- device would act on it using the address and endpoint the previous
        -- token left behind, which here would mean answering an IN that was
        -- never properly addressed.
        phy_rx(byte_arr'(0 => (not PID_IN) & PID_IN, 1 => x"07"), IDLE_J);
        service(3000, ok);
        check(not ok, "no response to a truncated token");
        phy_rx(token(PID_IN, 7, EP_FEEDBACK_IN), IDLE_J);
        service(4000, ok);
        check(ok and cap_n = 6, "still responsive after the runt");

        ----------------------------------------------------------------
        note("--- a packet the PHY flags as bad is not accepted ---");
        pkts := done_count;
        phy_rx(token(PID_OUT, 7, EP_AUDIO_OUT), IDLE_J);
        phy_rx(data_pkt(PID_DATA0, audio), IDLE_J, true);
        tick(20);
        check(done_count = pkts,
              "a receive error stops the packet being counted as good");

        ----------------------------------------------------------------
        note("--- feedback endpoint ---");
        phy_rx(token(PID_IN, 7, EP_FEEDBACK_IN), IDLE_J);
        service(4000, ok);
        check(ok and cap_n = 6, "feedback packet is PID + 3 bytes + CRC, got "
              & integer'image(cap_n) & " bytes");
        check_tx_crc("the feedback packet");
        if cap_n = 6 then
            check(cap(1) = x"00" and cap(2) = x"00" and cap(3) = x"0C",
                  "feedback reports 48.000 samples per frame");
        end if;

        ----------------------------------------------------------------
        note("--- unsupported request is stalled ---");
        phy_rx(token(PID_SETUP, 7, 0), IDLE_J);
        phy_rx(data_pkt(PID_DATA0, setup_pkt(16#80#, 16#99#, 0, 0, 2)), IDLE_J);
        service(4000, ok);
        phy_rx(token(PID_IN, 7, 0), IDLE_J);
        service(4000, ok);
        check(ok and cap(0)(3 downto 0) = x"E", "STALL returned");

        ----------------------------------------------------------------
        tick(50);
        if errs = 0 then
            note("ALL TESTS PASSED");
        else
            note("FAILURES: " & integer'image(errs));
        end if;
        running <= false;
        wait;
    end process;

end sim;
