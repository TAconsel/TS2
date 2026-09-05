library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Isochronous audio sink: USB byte stream in one clock domain, I2S samples in
-- another, and the feedback that keeps the two from drifting apart.
--
-- The board's audio clock is 48000.53 Hz -- the closest the PLL can get to 48k
-- from a 50 MHz reference -- while the host counts in exact 1 ms frames.  At
-- 11 ppm that is half a sample per second, which empties or overflows any
-- reasonable buffer in minutes.  Rather than resample, the device is declared
-- asynchronous and tells the host what rate it actually wants on the feedback
-- endpoint, so the host varies its packet size instead.
--
-- The reported rate has two parts.  The feedforward term is measured: audio
-- sample ticks are counted over 1024 SOF frames, which is a direct reading of
-- the audio clock against the host's frame clock, good to about 20 ppm.  The
-- correction term is proportional to how far the FIFO has drifted from half
-- full, which removes the residual and any startup transient.  Without the
-- first the loop would be slow to settle; without the second it would sit at a
-- constant offset and eventually run the buffer dry.
--
-- Channel alignment is re-established at every packet boundary rather than
-- tracked across the stream: a dropped or truncated packet costs a click, but
-- getting left and right permanently swapped would not fix itself.

entity usb_audio is
    Generic (
        -- 2**FIFO_BITS stereo samples of buffering; 512 is about 10 ms.
        FIFO_BITS : natural := 9
    );
    Port (
        ------------------------------------------------------------
        -- USB side, in the ULPI clock domain
        ------------------------------------------------------------
        usb_clk   : in  STD_LOGIC;
        rst       : in  STD_LOGIC;
        streaming : in  STD_LOGIC;
        sof       : in  STD_LOGIC;

        audio_data  : in STD_LOGIC_VECTOR(7 downto 0);
        audio_valid : in STD_LOGIC;
        audio_done  : in STD_LOGIC;
        audio_drop  : in STD_LOGIC;

        -- 10.14 samples per frame, for the feedback endpoint.
        fb_value : out unsigned(23 downto 0);
        -- Counts for the trace: packets taken, and buffer trouble.
        stat_over  : out unsigned(7 downto 0);
        stat_under : out unsigned(7 downto 0);

        ------------------------------------------------------------
        -- Audio side, in the I2S clock domain
        ------------------------------------------------------------
        aclk       : in  STD_LOGIC;
        frame_tick : in  STD_LOGIC;
        sample_l   : out signed(23 downto 0);
        sample_r   : out signed(23 downto 0);
        -- High once a real sample has been loaded.
        active     : out STD_LOGIC;
        -- High from the moment the host selects the streaming interface, which
        -- is when the DAC should follow USB rather than the test tone -- even
        -- while the buffer is still filling and the samples are silence.
        owns_dac   : out STD_LOGIC
    );
end usb_audio;

architecture Behavioral of usb_audio is

    -- 48 samples per frame exactly, in 10.14.
    constant FB_NOMINAL : natural := 48 * 16384;
    -- Never ask for less than 47 or more than 49 samples a frame, whatever the
    -- loop does; a wild request would make the host send packets that do not
    -- fit the endpoint.
    constant FB_MIN : natural := 47 * 16384;
    constant FB_MAX : natural := 49 * 16384;

    constant TARGET : natural := 2**(FIFO_BITS - 1);
    -- Proportional gain, as a left shift.  A one-sample error moves the
    -- request by 32/16384 of a sample per frame, so a ten-sample offset is
    -- pulled back over a few hundred frames.
    constant GAIN_SHIFT : natural := 5;

    ------------------------------------------------------------------
    -- USB domain
    ------------------------------------------------------------------
    signal phase : unsigned(1 downto 0) := (others => '0');
    signal b0, b1, b2 : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');

    signal wr_en   : STD_LOGIC := '0';
    signal wr_data : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal full    : STD_LOGIC;
    signal wr_level : unsigned(FIFO_BITS downto 0);

    signal sof_cnt  : unsigned(9 downto 0) := (others => '0');
    signal samp_cnt : unsigned(16 downto 0) := (others => '0');
    signal fb_meas  : unsigned(23 downto 0) :=
        to_unsigned(FB_NOMINAL, 24);

    signal tick_s1, tick_s2, tick_s3 : STD_LOGIC := '0';
    signal over_cnt, under_cnt : unsigned(7 downto 0) := (others => '0');

    ------------------------------------------------------------------
    -- Audio domain
    ------------------------------------------------------------------
    signal rd_en    : STD_LOGIC := '0';
    signal rd_data  : STD_LOGIC_VECTOR(31 downto 0);
    signal empty    : STD_LOGIC;
    signal rd_level : unsigned(FIFO_BITS downto 0);

    signal samp_tgl : STD_LOGIC := '0';
    signal held     : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal have     : STD_LOGIC := '0';
    -- A read takes two clocks to show up: one for rd_en to reach the FIFO,
    -- one for its registered output to settle.  This shift register tracks
    -- that so the sample is captured from the right cycle.
    signal pend     : STD_LOGIC_VECTOR(1 downto 0) := (others => '0');

    signal str_s1, str_s2 : STD_LOGIC := '0';
    -- Playback does not start into an empty buffer: it waits for the target
    -- level first.  Otherwise every stream begins with a few milliseconds of
    -- repeated samples while the FIFO fills, which is both an audible click
    -- and a burst of underruns in the statistics.
    signal primed : STD_LOGIC := '0';

    signal under_tgl : STD_LOGIC := '0';
    signal u_s1, u_s2, u_s3 : STD_LOGIC := '0';

begin

    ------------------------------------------------------------------
    -- Byte stream to stereo samples.  USB audio is little endian, left
    -- channel first, so four bytes make one FIFO word.
    ------------------------------------------------------------------
    process(usb_clk)
    begin
        if rising_edge(usb_clk) then
            wr_en <= '0';

            if audio_valid = '1' then
                case to_integer(phase) is
                    when 0 => b0 <= audio_data;
                    when 1 => b1 <= audio_data;
                    when 2 => b2 <= audio_data;
                    when others =>
                        wr_data <= b1 & b0 & audio_data & b2;
                        wr_en   <= '1';
                end case;
                phase <= phase + 1;
            end if;

            -- Every packet holds a whole number of frames, so realigning here
            -- costs nothing when all is well and repairs the channel order
            -- when a packet was short or corrupt.
            if audio_done = '1' or audio_drop = '1' then
                phase <= (others => '0');
            end if;

            if wr_en = '1' and full = '1' then
                over_cnt <= over_cnt + 1;
            end if;

            ----------------------------------------------------------
            -- Feedback loop
            ----------------------------------------------------------
            tick_s1 <= samp_tgl;
            tick_s2 <= tick_s1;
            tick_s3 <= tick_s2;
            if tick_s3 /= tick_s2 then
                samp_cnt <= samp_cnt + 1;
            end if;

            u_s1 <= under_tgl;
            u_s2 <= u_s1;
            u_s3 <= u_s2;
            if u_s3 /= u_s2 then
                under_cnt <= under_cnt + 1;
            end if;

            if sof = '1' then
                sof_cnt <= sof_cnt + 1;
                if sof_cnt = 1023 then
                    -- samp_cnt samples over 1024 frames, expressed as 10.14
                    -- samples per frame, is samp_cnt * 2**14 / 2**10.
                    fb_meas  <= resize(samp_cnt & "0000", 24);
                    samp_cnt <= (others => '0');
                end if;
            end if;

            if rst = '1' then
                phase    <= (others => '0');
                sof_cnt  <= (others => '0');
                samp_cnt <= (others => '0');
                fb_meas  <= to_unsigned(FB_NOMINAL, 24);
            end if;
        end if;
    end process;

    -- Reported rate: the measured rate, pulled towards whatever keeps the
    -- buffer half full, and clamped to something the endpoint can carry.
    process(usb_clk)
        variable corr : signed(31 downto 0);
        variable v    : signed(31 downto 0);
    begin
        if rising_edge(usb_clk) then
            corr := resize(signed('0' & std_logic_vector(wr_level)), 32)
                    - to_signed(TARGET, 32);
            -- A buffer filling up means the host is ahead: ask for less.
            v := resize(signed('0' & std_logic_vector(fb_meas)), 32)
                 - shift_left(corr, GAIN_SHIFT);
            if v < to_signed(FB_MIN, 32) then
                v := to_signed(FB_MIN, 32);
            elsif v > to_signed(FB_MAX, 32) then
                v := to_signed(FB_MAX, 32);
            end if;
            fb_value <= unsigned(std_logic_vector(v(23 downto 0)));
        end if;
    end process;

    stat_over  <= over_cnt;
    stat_under <= under_cnt;

    fifo : entity work.async_fifo
        generic map (WIDTH => 32, ADDR_BITS => FIFO_BITS)
        port map (
            wr_clk   => usb_clk,
            wr_en    => wr_en,
            wr_data  => wr_data,
            full     => full,
            rd_clk   => aclk,
            rd_en    => rd_en,
            rd_data  => rd_data,
            empty    => empty,
            rd_level => rd_level,
            wr_level => wr_level
        );

    ------------------------------------------------------------------
    -- Audio domain: one stereo sample per I2S frame.
    ------------------------------------------------------------------
    process(aclk)
    begin
        if rising_edge(aclk) then
            rd_en <= '0';

            str_s1 <= streaming;
            str_s2 <= str_s1;

            pend <= pend(0) & '0';
            if pend(1) = '1' then
                held <= rd_data;
                have <= '1';
            end if;

            if str_s2 = '0' then
                -- Nothing is streaming: throw away anything left over rather
                -- than playing it late when the host comes back.
                have   <= '0';
                primed <= '0';
                pend   <= (others => '0');
                if empty = '0' then
                    rd_en <= '1';
                end if;
            elsif frame_tick = '1' then
                samp_tgl <= not samp_tgl;
                if primed = '0' then
                    if rd_level >= TARGET then
                        primed <= '1';
                    end if;
                elsif empty = '0' then
                    rd_en   <= '1';
                    pend(0) <= '1';
                else
                    -- Underrun: hold the last sample rather than jumping to
                    -- zero, which is the quieter of the two failures.
                    under_tgl <= not under_tgl;
                end if;
            end if;
        end if;
    end process;

    -- 16-bit samples sit in the top of the 24-bit I2S word, the same
    -- placement the test tone uses.
    sample_l <= shift_left(resize(signed(held(31 downto 16)), 24), 8)
                when have = '1' else (others => '0');
    sample_r <= shift_left(resize(signed(held(15 downto 0)), 24), 8)
                when have = '1' else (others => '0');
    active   <= have;
    owns_dac <= str_s2;

end Behavioral;
