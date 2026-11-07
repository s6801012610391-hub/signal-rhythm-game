
function [noteName,f0,confidence,rmsADC,diagnostic] = ...
    detectLivePitch(adc,Fs,rmsGate)

% LIVE YIN PITCH DETECTION
% Input:
%   adc     - Recent ADC samples
%   Fs      - Sampling frequency
%   rmsGate - Silence detection threshold
%
% Output:
%   noteName   - Detected musical note
%   f0         - Fundamental frequency
%   confidence - YIN periodicity indicator
%   rmsADC     - RMS amplitude in ADC counts

    if nargin < 3
        rmsGate = 30;
    end

    % Optional observation only. The first four outputs and decisions stay unchanged.
    diagnostic = struct('Reason',"INSUFFICIENT_SAMPLES",'RawRMS',NaN, ...
        'FilteredRMS',NaN,'MinCMNDF',NaN,'CMNDFThreshold',0.45, ...
        'RawRMSGate',rmsGate,'FilteredRMSGate',8,'ConfidenceGate',0.55, ...
        'CandidateTau',NaN,'CandidateHz',NaN,'InterpolatedHz',NaN, ...
        'MIDIDiagnostic',NaN,'MIDIDecision',NaN,'CandidateConfidence',NaN, ...
        'InterpolationReached',false,'MIDIReached',false, ...
        'InterpolationStatus',"not_available",'CMNDFCurve',[], ...
        'Fs',Fs,'InputSampleCount',numel(adc),'AnalysisLength',2048, ...
        'ADCMin',NaN,'ADCMax',NaN,'ADCMean',NaN,'ClipLowCount',NaN,'ClipHighCount',NaN);

    noteName = "---";
    f0 = NaN;
    confidence = 0;
    rmsADC = 0;

    % Analysis frame
    N = 2048;

    if numel(adc) < N
        return;
    end

    % Latest audio frame
    x = double(adc(end-N+1:end));
    x = x(:);
    diagnostic.ADCMin = min(x);
    diagnostic.ADCMax = max(x);
    diagnostic.ADCMean = mean(x);
    diagnostic.ClipLowCount = sum(x <= 0);
    diagnostic.ClipHighCount = sum(x >= 4095);

    % Remove DC offset
    x = x - mean(x);

    % RMS amplitude
    rmsADC = sqrt(mean(x.^2));
    diagnostic.RawRMS = rmsADC;

    % Silence / noise rejection
    if rmsADC < rmsGate
        diagnostic.Reason = "RAW_RMS_GATE";
        return;
    end




    % Filter interference before YIN
    % Keep approximately 230-1100 Hz

    X = fft(x);

    freqBins = (0:N-1)' * Fs/N;

    keep = ...
        (freqBins >= 230 & freqBins <= 1100) | ...
        (freqBins >= Fs-1100 & freqBins <= Fs-230);


    x = real(ifft(X .* double(keep)));

    % Normalize the filtered signal
    filteredRMS = sqrt(mean(x.^2));
    diagnostic.FilteredRMS = filteredRMS;

    if filteredRMS < 8
        diagnostic.Reason = "FILTERED_RMS_GATE";
        return;
    end

    x = x / (filteredRMS + eps);


    % Frequency search range for C4-B4
    fmin = 240;
    fmax = 530;

    tauMin = max(2,floor(Fs/fmax));
    tauMax = min(ceil(Fs/fmin),N-2);

    % YIN difference function
    d = zeros(1,tauMax);

    M = N-tauMax;

    for tau = 1:tauMax
        difference = x(1:M) - x((1:M)+tau);
        d(tau) = sum(difference.^2);
    end

    % Cumulative Mean Normalized Difference
    cmndf = ones(1,tauMax);

    cumulative = 0;

    for tau = 1:tauMax
        cumulative = cumulative+d(tau);

        if tau > 1
            cmndf(tau) = ...
                tau*d(tau)/(cumulative+eps);
        end
    end
    

    % ===== TEMPORARY YIN DIAGNOSTIC =====
    [minCMNDF, idx] = min(cmndf(tauMin:tauMax));

    candidateTau = tauMin + idx - 1;
    candidateFreq = Fs / candidateTau;

    diagnostic.MinCMNDF = minCMNDF;
    diagnostic.CandidateTau = candidateTau;
    diagnostic.CandidateHz = candidateFreq;
    diagnostic.CandidateConfidence = max(0,1-minCMNDF);
    if nargout >= 5
        % A hypothetical interpolation for rejected frames, never used to accept them.
        diagnostic.InterpolatedHz = diagnosticInterpolation(cmndf,candidateTau,tauMax,Fs);
        diagnostic.MIDIDiagnostic = round(69+12*log2(diagnostic.InterpolatedHz/440));
        diagnostic.InterpolationStatus = "diagnostic_only";
        diagnostic.CMNDFCurve = cmndf;
    end

    fprintf(['YIN DEBUG | CMNDF %.3f | ' ...
        'Candidate %.1f Hz | RMS %.1f\n'], ...
        minCMNDF, candidateFreq, rmsADC);


    % Find the strongest periodicity candidate
    threshold = 0.45;
    diagnostic.CMNDFThreshold = threshold;

    % Select minimum CMNDF in the allowed range
    [minValue, index] = min(cmndf(tauMin:tauMax));

    % Reject weak periodicity
    if minValue >= threshold
        diagnostic.Reason = "CMNDF_GATE";
        return;
    end

    bestTau = tauMin + index - 1;


    % Parabolic interpolation
    tauEstimate = bestTau;

    if bestTau > 1 && bestTau < tauMax

        a = cmndf(bestTau-1);
        b = cmndf(bestTau);
        c = cmndf(bestTau+1);

        denominator = a-2*b+c;

        if abs(denominator) > 1e-12

            shift = 0.5*(a-c)/denominator;
            shift = max(-1,min(1,shift));

            tauEstimate = bestTau+shift;
        end
    end

    % Fundamental frequency
    f0 = Fs/tauEstimate;
    diagnostic.InterpolationReached = true;
    diagnostic.InterpolatedHz = f0;
    diagnostic.InterpolationStatus = "used_by_detector";

    % Periodicity confidence
    confidence = max(0,1-cmndf(bestTau));

    if confidence < 0.55
        diagnostic.Reason = "CONFIDENCE_GATE";
        f0 = NaN;
        return;
    end

    % Frequency -> MIDI
    midi = round(69+12*log2(f0/440));
    diagnostic.MIDIReached = true;
    diagnostic.MIDIDecision = midi;
    diagnostic.MIDIDiagnostic = midi;

    % Allowed octave
    if midi < 60 || midi > 71
        diagnostic.Reason = "MIDI_RANGE";
        f0 = NaN;
        return;
    end

    % MIDI -> Note Name
    names = {'C','C#','D','D#','E','F', ...
             'F#','G','G#','A','A#','B'};

    noteIndex = mod(midi,12)+1;
    octave = floor(midi/12)-1;

    noteName = sprintf('%s%d', ...
        names{noteIndex},octave);
    diagnostic.Reason = "ACCEPTED";

end

function frequency = diagnosticInterpolation(cmndf,tau,tauMax,Fs)
% Mirrors the existing interpolation for observation; never feeds the detector.
    estimate = tau;
    if tau > 1 && tau < tauMax
        a = cmndf(tau-1);
        b = cmndf(tau);
        c = cmndf(tau+1);
        denominator = a-2*b+c;
        if abs(denominator) > 1e-12
            shift = 0.5*(a-c)/denominator;
            shift = max(-1,min(1,shift));
            estimate = tau+shift;
        end
    end
    frequency = Fs/estimate;
end
