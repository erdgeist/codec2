% newamp2_batch.m
%
% Copyright David Rowe 2018
% This program is distributed under the terms of the GNU General Public License 
% Version 2
%

#{

  Octave script to batch process model parameters using the new
  amplitude model, version 2.  Outputs another set of model parameters
  that can be fed to c2sim for listening tests.  The companion
  newamp2_fbf.m script is used to visualise the processing frame by frame
 
  c2sim -> dump files -> newamp1_batch.m -> output model params -> c2sim -> play
 
  Usage:

    build codec2 with -DDUMP - see codec2-dev/README, then:

    ~/codec2-dev/build_linux/src$ ./c2sim ../../raw/hts1a.raw --dump hts1a
    $ cd ~/codec2-dev/octave
    octave:14> newamp2_batch("../build_linux/src/hts1a")
    ~/codec2-dev/build_linux/src$ /c2sim ../../raw/hts1a.raw --pahw hts1a -o - | aplay -f S16 
#}


function surface = newamp2_batch(input_prefix, varargin)
  newamp2;
  more off;

  max_amp = 160; Fs = 8000;

  % defaults

  synth_phase = output = 1;
  output_prefix = input_prefix;
  mode = "mel";
  correct_rate_K_en = 0; quant = ""; vq_en = 0;
  
  % parse variable argument list

  if (length (varargin) > 0)

    % check for the "output_prefix" option

    ind = arg_exists(varargin, "output_prefix");
    if ind
      output_prefix =  varargin{ind+1};
    end

    ind = arg_exists(varargin, "mode");
    if ind
      mode =  varargin{ind+1};
    end

    ind = arg_exists(varargin, "no_output");
    if ind
      output = 0;
      synth_phase = 0;
    end

    if arg_exists(varargin, "huffman")
      quant = "huffman";
    end
    if arg_exists(varargin, "dct")
      quant = "dct";
    end
    if arg_exists(varargin, "dtlimit")
      quant = "dtlimit";
    end
     
    ind = arg_exists(varargin, "vq");
    if ind
      vq_en = 1; vq_name = varargin{ind+1}; vq_st = varargin{ind+2}; vq_en = varargin{ind+3};
    end
    
    correct_rate_K_en = arg_exists(varargin, "correct_rate_K");
  end

  printf("output: %d", output);
  if (output)
    printf(" output_prefix: %s",  output_prefix);
  end
  printf(" mode: %s", mode);
  printf(" correct_rate_K: %d quant: %s vq_en: %d\n", correct_rate_K_en, quant, vq_en);
  if vq_en
    printf("vq_name: %s vq_st: %d vq_en: %d\n", vq_name, vq_st, vq_en);
  end
  
  model_name = strcat(input_prefix,"_model.txt");
  model = load(model_name);
  [frames nc] = size(model);

  voicing_name = strcat(input_prefix,"_pitche.txt");
  voicing = zeros(1,frames);
  
  if exist(voicing_name, "file") == 2
    pitche = load(voicing_name);
    voicing = pitche(:, 3);
  end

  % Choose experiment to run test here -----------------------

  if strcmp(mode, 'mel')
    if vq_en
      load(vq_name);
      size(avq)
      vqs.st=vq_st; vqs.en=vq_en; vqs.m=5;
      vqs.table = avq;
      [model_ surface sd_log] = experiment_mel_freq(model, correct_rate_K_en, plots=1, quant, vqs);
    else
      [model_ surface sd_log] = experiment_mel_freq(model, correct_rate_K_en, plots=1, quant);
    end
  end

  % ----------------------------------------------------

  if output
    Am_out_name = sprintf("%s_am.out", output_prefix);
    fam  = fopen(Am_out_name,"wb"); 
 
    Wo_out_name = sprintf("%s_Wo.out", output_prefix);
    fWo  = fopen(Wo_out_name,"wb"); 
  
    if synth_phase
      Hm_out_name = sprintf("%s_hm.out", output_prefix);
      fhm = fopen(Hm_out_name,"wb"); 
    end

    for f=1:frames
      %printf("%d ", f);   
      Wo = model_(f,1); L = min([model_(f,2) max_amp-1]); Am = model_(f,3:(L+2));
      if Wo*L > pi
        printf("Problem: %d  Wo*L > pi Wo: %f F0: %f L: %d Wo*L: %f\n", f, Wo, Wo*Fs/(2*pi), L, Wo*L);   
      end

      Am_ = zeros(1,max_amp); Am_(2:L) = Am(1:L-1); fwrite(fam, Am_, "float32");
      fwrite(fWo, Wo, "float32");

      if synth_phase

        % synthesis phase spectra from magnitiude spectra using minimum phase techniques

        fft_enc = 512;
        phase = determine_phase(model_, f, fft_enc);
        assert(length(phase) == fft_enc);

        % sample phase at centre of each harmonic, not 1st entry Hm(1:2) in octave Hm[0] in C
        % is not used

        Hm = zeros(1, 2*max_amp);
        for m=1:L
          b = round(m*Wo*fft_enc/(2*pi));
          Hm(2*m+1) = cos(phase(b));
          Hm(2*m+2) = sin(phase(b));
        end
        fwrite(fhm, Hm, "float32");
      end
    end
 
   fclose(fam);
   fclose(fWo);
   if synth_phase
     fclose(fhm);
   end

   % save voicing file
  
   if exist("voicing_", "var")
     v_out_name = sprintf("%s_v.txt", output_prefix);
     fv  = fopen(v_out_name,"wt"); 
     for f=1:length(voicing_)
       fprintf(fv,"%d\n", voicing_(f));
     end
     fclose(fv);
    end
  end

  printf("\n")

endfunction
 

function ind = arg_exists(v, str) 
   ind = 0;
   for i=1:length(v)
      if !ind && strcmp(v{i}, str)
        ind = i;
      end     
    end
endfunction


% Basic unquantised rate K mel-sampling then back to rate L

function [model_ rate_K_surface_ sd_log delta_K] = experiment_mel_freq(model, correct_rate_K_en=0, plots=1, quant="", vq)
  [frames nc] = size(model);
  K = 20; Fs = 8000;
  AmdB = zeros(frames, 160);
  melvq;
  
  for f=1:frames
    Wo = model(f,1);
    L = model(f,2);
    Am = model(f,3:(L+2));
    AmdB(f,1:L) = 20*log10(Am);
    Am_freqs_kHz = (1:L)*Wo*Fs/(2000*pi);
    [rate_K_vec rate_K_sample_freqs_kHz] = resample_const_rate_f_mel(model(f,:), K, Fs, 'lanc');
    if correct_rate_K_en
      [tmp_ AmdB_] = resample_rate_L(model(f,:), rate_K_vec, rate_K_sample_freqs_kHz, Fs, 'lancmel');
      [rate_K_vec_corrected orig_error error nasty_error_log nasty_error_m_log] = correct_rate_K_vec(rate_K_vec, rate_K_sample_freqs_kHz, AmdB, AmdB_, K, Wo, L, Fs);
      rate_K_surface(f,:) = rate_K_vec_corrected;
    else
      rate_K_surface(f,:) = rate_K_vec;
    end
  end

  % expriment to limit frame by frame changes, this will make quantisation easier

  if strcmp(quant,"dtlimit");
    rate_K_surface_prev_ = zeros(1,K);
    delta_K_log = zeros(frames,K);

    for f=1:frames

      % find delta

      delta_K = rate_K_surface(f,:) - rate_K_surface_prev_;

      % limit to -6,0,+6 dB 

      delta_K = 6*round(delta_K/6);
      delta_K = min(delta_K, +12);
      delta_K = max(delta_K, -12);

      % optional VQ

      if nargin == 5
        [res output_vec ind] = mbest(vq.table, delta_K(:,vq.st:vq.en), vq.m);
        delta_K(:,vq.st:vq.en) = output_vec;
      end
      
      rate_K_surface_prev_ += delta_K;
      rate_K_surface_(f,:) = rate_K_surface_prev_;
      delta_K_log(f,:) = delta_K;
    end
  end

  % huffman encoding of delata_f, also limits delta_f changes, (hopefully) making quantisation easier

  if strcmp(quant,"huffman");
    for f=1:frames
      rate_K_surface_(f,:) = huffman_quantise_rate_K(rate_K_surface(f,:));
    end
    if nargin == 5
      size(vq.table)
      target = (rate_K_surface_(:,vq.st:vq.en) - rate_K_surface_(:,3))/6;
      [res output_vecs ind] = mbest(vq.table, target, vq.m);
      rate_K_surface_(:,vq.st:vq.en) = 6*output_vecs + rate_K_surface_(:,3);
    end
  end

  if strcmp(quant,"dct");
    for f=1:frames
      rate_K_surface_(f,:) = dct_quantise_rate_K(rate_K_surface(f,:));
    end
  end 
  if strcmp(quant,"");
    rate_K_surface_ = rate_K_surface;
  end
  
  if plots
    l = min(100, length(rate_K_surface_));
    figure(1); clf; mesh(rate_K_surface_(1:l,:));
  end

  [model_ AmdB_ ] = resample_rate_L(model, rate_K_surface_, rate_K_sample_freqs_kHz, Fs, 'lancmel');

  % calculate SD

  sd_log = []; energy_log = [];
  for f=1:frames
    L = model(f,2);
    asd = std(AmdB(f,1:L) - AmdB_(f,1:L));
    energy_log = [energy_log mean(AmdB(f,1:L))];
    sd_log = [sd_log asd];
  end

  if plots
    figure(2); clf; l = length(sd_log); ax=plotyy((1:l),sd_log,(1:l),energy_log);
    title('SD againstframe'); xlabel('Frame'); ylabel (ax(1), "SD"); ylabel (ax(2), "Energy");

    figure(3); clf; plot(hist(sd_log)); title('SD histogram');
    figure(4); clf; plot(energy_log, sd_log, '+'); title('Scatter of SD against energy');
    xlabel('Energy'); ylabel('SD'); axis([-10 60 0 7]);
  end
  
  % return delta_K for training
  
  if strcmp(quant,"dtlimit")
    rate_K_surface_ = delta_K_log;
    l = min(100, length(rate_K_surface_));
    figure(5); clf; mesh(rate_K_surface_(1:l,:));
  end

  % this code useful to explore outliers, adjust threshold based on plot(sd_log)

  plot_outliers = 0;
  if plot_outliers && (asd > 7)
    for f=1:frames
      L = model(f,2);
      figure; plot(AmdB(f,1:L), 'b+-'); hold on; plot(AmdB_(f,1:L), 'r+-'); hold off;
    end
  end
  printf("mean SD %4.2f\n", mean(sd_log));

endfunction

