library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.TEXTIO.all;

-- Testbench for usb_audio: the byte stream from the SIE in one clock domain,
-- I2S samples out in another, and the feedback loop in between.
--
-- Both clocks are the real ones -- 60 MHz for ULPI and 98.295455 MHz for the
-- audio side -- so the crossing is exercised at its actual ratio rather than
-- at some convenient integer one.  Bytes arrive one per clock, which is what
-- high speed actually delivers and the hardest case for the packer.  Sample values are made distinguishable per
-- channel so a swapped or shifted pair is visible rather than merely wrong by
-- a little.

entity tb_usb_audio is
end tb_usb_audio;

architecture sim of tb_usb_audio is

    constant USB_PERIOD : time := 16.667 ns;    -- 60 MHz
    constant A_PERIOD   : time := 10.173 ns;    -- 98.295455 MHz
    -- The I2S master ticks once per 256 audio clocks.
    constant FRAME_DIV  : natural := 256;

    signal usb_clk : STD_LOGIC := '0';
    signal aclk    : STD_LOGIC := '0';
    signal running : boolean := true;

    signal rst       : STD_LOGIC := '1';
    signal streaming : STD_LOGIC := '0';
    signal sof       : STD_LOGIC := '0';

    signal audio_data  : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal audio_valid : STD_LOGIC := '0';
    signal audio_done  : STD_LOGIC := '0';
    signal audio_drop  : STD_LOGIC := '0';

    signal fb_value   : unsigned(31 downto 0);
    signal stat_over  : unsigned(7 downto 0);
    signal stat_under : unsigned(7 downto 0);

    signal frame_tick : STD_LOGIC := '0';
    signal sample_l, sample_r : signed(31 downto 0);
    signal active, owns_dac : STD_LOGIC;

    signal got    : natural := 0;
    signal bad    : natural := 0;
    signal prev_l : natural := 0;
    signal first  : STD_LOGIC := '1';
    -- Only the checker drives the counters, so restarting them is a request
    -- rather than an assignment from the stimulus process.
    signal clear_stats : STD_LOGIC := '0';

begin

    usb_clk <= (not usb_clk) after USB_PERIOD / 2 when running else '0';
    aclk    <= (not aclk)    after A_PERIOD / 2   when running else '0';

    dut : entity work.usb_audio
        generic map (FIFO_BITS => 10)
        port map (
            usb_clk     => usb_clk,
            rst         => rst,
            streaming   => streaming,
            sof         => sof,
            audio_data  => audio_data,
            audio_valid => audio_valid,
            audio_done  => audio_done,
            audio_drop  => audio_drop,
            fb_value    => fb_value,
            stat_over   => stat_over,
            stat_under  => stat_under,
            aclk        => aclk,
            frame_tick  => frame_tick,
            sample_l    => sample_l,
            sample_r    => sample_r,
            active      => active,
            owns_dac    => owns_dac
        );

    -- The I2S frame tick, as the transmitter generates it.
    ticker : process(aclk)
        variable n : natural := 0;
    begin
        if rising_edge(aclk) then
            frame_tick <= '0';
            n := n + 1;
            if n = FRAME_DIV then
                n := 0;
                frame_tick <= '1';
            end if;
        end if;
    end process;

    -- Check what the DAC would see against the invariants of the stimulus
    -- rather than against a running index: sample k carries left = 2k and
    -- right = 2k + 1, so the right channel must always be one above the left,
    -- and consecutive samples must step by two.  Written this way the check
    -- needs no synchronisation with the sender, and it tolerates the sink
    -- deliberately repeating its last sample through an underrun.
    checker : process(aclk)
        variable l, r : integer;
    begin
        if rising_edge(aclk) then
            if clear_stats = '1' then
                got   <= 0;
                bad   <= 0;
                first <= '1';
            elsif frame_tick = '1' and active = '1' then
                l := to_integer(sample_l) mod 65536;
                r := to_integer(sample_r) mod 65536;
                if r /= (l + 1) mod 65536 then
                    bad <= bad + 1;             -- channels out of step
                elsif first = '0'
                      and l /= prev_l
                      and l /= (prev_l + 2) mod 65536 then
                    bad <= bad + 1;             -- a sample went missing
                end if;
                prev_l <= l;
                first  <= '0';
                got    <= got + 1;
            end if;
        end if;
    end process;

    main : process

        variable errs : natural := 0;

        procedure note(s : string) is
            variable l : line;
        begin
            write(l, now, right, 10, ns);
            write(l, string'("  "));
            write(l, s);
            writeline(output, l);
        end procedure;

        procedure check(cond : boolean; s : string) is
        begin
            if cond then
                note("ok   " & s);
            else
                note("FAIL: " & s);
                errs := errs + 1;
            end if;
        end procedure;

        procedure utick(n : natural := 1) is
        begin
            for i in 1 to n loop
                wait until rising_edge(usb_clk);
            end loop;
        end procedure;

        -- High speed delivers a byte every ULPI clock, with no gap.
        procedure send_byte(b : integer) is
        begin
            audio_data  <= std_logic_vector(to_unsigned(b mod 256, 8));
            audio_valid <= '1';
            utick;
            audio_valid <= '0';
        end procedure;

        -- One microframe's worth: n stereo samples, four bytes each, little
        -- endian, left channel first.
        procedure send_sample(v : integer) is
        begin
            send_byte(v mod 256);
            send_byte((v / 256) mod 256);
            send_byte((v / 65536) mod 256);
            send_byte((v / 16777216) mod 256);
        end procedure;

        procedure send_packet(first : natural; n : natural; good : boolean) is
        begin
            for k in 0 to n - 1 loop
                send_sample((2 * (first + k)) mod 65536);
                send_sample((2 * (first + k) + 1) mod 65536);
            end loop;
            if good then
                audio_done <= '1';
            else
                audio_drop <= '1';
            end if;
            utick;
            audio_done <= '0';
            audio_drop <= '0';
        end procedure;

        variable sent : natural := 0;

    begin
        note("start");
        utick(5);
        rst <= '0';
        utick(5);
        streaming <= '1';
        utick(200);

        -- Prime the buffer, then keep feeding it one packet per frame while
        -- the audio side drains it, which is what the host does.
        -- Enough packets to get past the priming level -- the buffer must
        -- reach half of its 1024 entries before playback starts.
        note("--- streaming 48-sample microframes ---");
        for p in 0 to 13 loop
            send_packet(sent, 48, true);
            sent := sent + 48;
        end loop;

        check(got > 0, "samples reached the DAC side");
        check(bad = 0, "every sample in order and in the right channel, "
              & integer'image(bad) & " bad of " & integer'image(got));

        -- Let the audio side catch up: fourteen microframes is 672 samples,
        -- about 1.75 ms at 384 kHz, so it takes a little longer to run dry.
        wait for 2500 us;
        check(bad = 0, "still matching after the buffer drained, "
              & integer'image(got) & " samples checked");
        check(stat_over = 0, "no FIFO overflow");
        check(stat_under > 0, "underrun reported once the buffer ran dry");

        ----------------------------------------------------------------
        note("--- feedback follows the buffer level ---");
        -- A buffer below the half-full target means the device is consuming
        -- faster than the host is filling, so it must ask for more.
        check(fb_value > to_unsigned(48 * 65536, 32),
              "a draining buffer asks for more than 48 samples a microframe, "
              & "got " & integer'image(to_integer(fb_value)));
        check(fb_value <= to_unsigned(49 * 65536, 32),
              "and stays inside the clamp");

        -- Push well past the half-full mark and it must ask for fewer.
        for p in 0 to 15 loop
            send_packet(sent, 48, true);
            sent := sent + 48;
        end loop;
        utick(50);
        check(fb_value < to_unsigned(48 * 65536, 32),
              "a filling buffer asks for less than 48 samples a microframe, "
              & "got " & integer'image(to_integer(fb_value)));
        check(fb_value >= to_unsigned(47 * 65536, 32),
              "and stays inside the clamp");

        ----------------------------------------------------------------
        note("--- a dropped packet does not shift the channels ---");
        wait for 3 ms;
        -- Three bytes then a drop: part of a sample, which would shift left
        -- and right from here on if the phase were not reset at the boundary.
        send_byte(16#11#);
        send_byte(16#22#);
        send_byte(16#33#);
        audio_drop <= '1';
        utick;
        audio_drop <= '0';
        utick(50);

        clear_stats <= '1';
        wait for 1 us;
        clear_stats <= '0';
        utick(10);
        -- The sample sequence carries on rather than restarting, so the
        -- continuity check stays meaningful across the gap.
        for p in 0 to 13 loop
            send_packet(sent, 48, true);
            sent := sent + 48;
        end loop;
        wait for 2500 us;
        check(bad = 0, "channels still aligned after the truncated packet, "
              & integer'image(bad) & " bad of " & integer'image(got));

        if errs = 0 then
            note("ALL TESTS PASSED");
        else
            note("FAILURES: " & integer'image(errs));
        end if;
        running <= false;
        wait;
    end process;

end sim;
