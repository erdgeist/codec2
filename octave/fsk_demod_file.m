% fsk_demod_file.m
% David Rowe May 2020
%
% Demodulate a file of off air samples and plot a bunch of internal
% states. Useful for debugging the FSK demod configuration

#{
   Sample usage to explore demodulator operation with a 100 bits/s 2FSK signal:

   $ cd ~/codec2/build_linux/src
   $ ./fsk_get_test_bits - 1000 | ./fsk_mod 2 8000 100 1000 1000 - ../../octave/fsk.s16
   $ octave --no-gui
   octave:1> fsk_demod_file("fsk.s16",format="s16",8000,100,2)

   Same thing but complex )single sided):
   
   $ ./fsk_get_test_bits - 1000 | ./fsk_mod 2 8000 100 1000 1000 - - | ./cohpsk_ch - fsk.cs16 -100 --FS 8000 --complexout
   octave:2> fsk_demod_file("fsk.cs16",format="cs16",8000,100,2)
#}

function fsk_demod_file(filename, format="s16", Fs=8000, Rs=50, M=2, max_secs=1E32)
  more off;
  fsk_lib;
  plot_en = 1;
  if strcmp(format,"s16")
    read_complex = 0; sample_size = 'int16'; shift_fs_on_4=0;
  elseif strcmp(format,"cs16")
    read_complex = 1; sample_size = 'int16'; shift_fs_on_4=0;
  else
    printf("Error in format: %s\n", format);
    return;
  end

  fin = fopen(filename,"rb");
  if fin == -1 printf("Error opneing file: %s\n",filename); return; end
  
  states = fsk_init(Fs, Rs, M);
  nbit = states.nbit;

  frames = 0;
  rx = []; rx_bits_log = []; rx_bits_sd_log = []; norm_rx_timing_log = [];
  f_int_resample_log = []; EbNodB_log = []; ppm_log = [];
  f_log = []; Sf_log = [];
  
  % Extract raw bits from samples ------------------------------------------------------

  printf("demod of raw bits....\n");

  finished = 0; ph = 1; secs = 0;
  while (finished == 0)

    % read nin samples from input file

    nin = states.nin;
    if read_complex
      [sf count] = fread(fin, 2*nin, sample_size);
      if sample_size == "uint8" sf = (sf - 127)/128; end
      sf = sf(1:2:end) + j*sf(2:2:end);
      count /= 2;
      if shift_fs_on_4
        % optional shift up in freq by Fs/4 to get into freq est range
        for i=1:count
          ph = ph*exp(j*pi/4);
          sf(i) *= ph;
        end
      end
    else
      [sf count] = fread(fin, nin, "short");
    end
    rx = [rx; sf];
    
    if count == nin
      frames++;

      % demodulate to stream of bits

      states = est_freq(states, sf, states.M);
      if states.freq_est_type == 'mask' states.f = states.f2; end
      [rx_bits states] = fsk_demod(states, sf);

      rx_bits_log = [rx_bits_log rx_bits];
      rx_bits_sd_log = [rx_bits_sd_log states.rx_bits_sd];
      norm_rx_timing_log = [norm_rx_timing_log states.norm_rx_timing];
      f_int_resample_log = [f_int_resample_log abs(states.f_int_resample)];
      EbNodB_log = [EbNodB_log states.EbNodB];
      ppm_log = [ppm_log states.ppm];
      f_log = [f_log; states.f];
      Sf_log = [Sf_log; states.Sf'];
    else
      finished = 1;
    end

    secs += nin/Fs;
    if secs > max_secs finished=1; end
      
  end
  printf("frames: %d\n", frames);
  fclose(fin);

  if plot_en
    printf("plotting...\n");

    figure(1); clf;
    rx_nowave = rx(1000:length(rx)); % skip past wav header if it's a wave file
    subplot(211)
    plot(real(rx_nowave));
    title('input signal to demod (1 sec)')
    xlabel('Time (samples)');
    subplot(212);
    last = min(length(rx_nowave),states.Fs);
    RxdBFS = 20*log10(abs(fft(rx_nowave(1:last))));
    mx = 10*ceil(max(RxdBFS/10));
    plot(RxdBFS);
    axis([1 length(RxdBFS) mx-80 mx])
    xlabel('Frequency (Hz)');

    figure(2); plot_specgram(rx,Fs);
    figure(3); clf; plot(f_log,'+-'); axis([1 length(f_log) -Fs/2 Fs/2]); title('Tone Freq Estimates');    
    figure(4); clf; mesh(Sf_log(1:10,:)); title('Freq Est Sf over time');
    figure(5); clf; plot(f_int_resample_log','+'); title('Integrator outputs for each tone');
    figure(6); clf; plot(norm_rx_timing_log); axis([1 frames -0.5 0.5]); title('norm fine timing')
    figure(7); clf; plot(EbNodB_log); title('Eb/No estimate')
    figure(8); clf; plot(ppm_log); title('Sample clock (baud rate) offset in PPM');

  end

endfunction
