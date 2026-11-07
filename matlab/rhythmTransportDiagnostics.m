function [s, report] = rhythmTransportDiagnostics(action, s, varargin)
%ENV20DEBUG Continuous 20-ms RMS diagnostics; legacy=200, Task3=320 samples.
% init:   s = rhythmTransportDiagnostics("init", [], Fs)
% push:   s = rhythmTransportDiagnostics("push", s, packet, adc, readGameTime)
% finish: [s,r] = rhythmTransportDiagnostics("finish", s, rawBytesRemaining, ...
%                          publishToBase, expectedReceivedSamples)
% The last two finish arguments default to true and NaN respectively.
% Audio times index ACCEPTED samples, not reconstructed acquisition time.
% Invalid rows retain their numerical RMS for inspection only.

    report = [];
    switch string(action)
        case "init"
            validateattributes(varargin{1}, {'numeric'}, ...
                {'scalar','real','finite','positive'});
            s = struct('Fs',double(varargin{1}), ...
                'FrameSamples',max(1,round(double(varargin{1})*0.020)), ...
                'Protocol',"",'MissedTicksAvailable',double(varargin{1})==10000, ...
                'Received',0, 'NextSample',1, ...
                'Pending',zeros(0,1), 'PendingValid',false(0,1), ...
                'LastSeq',NaN, 'LastMissed',NaN, ...
                'FirstSeq',NaN, 'FirstMissed',NaN, 'Segment',1, ...
                'Faults',zeros(1,3), ...
                'Rows',zeros(512,8), 'Count',0, ...
                'Events',zeros(0,11), 'Reported',false, 'Report',[]);

        case "push"
            assert(~s.Reported, 'rhythmTransportDiagnostics:Finished', ...
                'Initialize a new ENV20 session before pushing more packets.');
            packet = varargin{1};
            adc = varargin{2};
            readGameTime = varargin{3};
            meta = rhythmPacketMetadata(packet,s.Fs);
            validateattributes(adc, {'numeric'}, ...
                {'vector','numel',1024,'real','finite','integer','>=',0,'<=',4095});
            validateattributes(readGameTime, {'numeric'}, ...
                {'scalar','real','finite','nonnegative'});
            adc = double(adc(:));
            if s.Protocol ~= ""
                assert(s.Protocol==meta.Protocol,'ENV20 protocol changed during session.');
            end
            s.Protocol = meta.Protocol;
            s.MissedTicksAvailable = meta.MissedTicksAvailable;
            seq = meta.Sequence;
            missed = meta.MissedTicks;

            % Firmware missedTicks is cumulative, not a per-packet count.
            seqStep = NaN;
            missedStep = NaN;
            metadataBreak = false;
            firstPacket = isnan(s.LastSeq);
            initialUncertain = firstPacket && isfinite(missed) && missed ~= 0;
            if firstPacket
                s.FirstSeq = seq;
                s.FirstMissed = missed;
            else
                seqStep = mod(seq-s.LastSeq,2^32);
                if isfinite(missed) && isfinite(s.LastMissed)
                    missedStep = mod(missed-s.LastMissed,2^32);
                end
                metadataBreak = seqStep ~= 1 || (isfinite(missedStep) && missedStep ~= 0);
            end

            % Faults: [resync bytes, invalid packets, receive errors].
            broken = metadataBreak || initialUncertain || any(s.Faults ~= 0);
            if broken
                s.Events(end+1,:) = [ ...
                    s.Received+1, s.LastSeq, seq, seqStep, ...
                    s.LastMissed, missed, missedStep, s.Faults, ...
                    double(initialUncertain)];
                s.Segment = s.Segment+1;
                s.PendingValid(:) = false;
            end
            s.LastSeq = seq;
            s.LastMissed = missed;
            s.Faults(:) = 0;

            % Process every complete window before discarding any samples.
            x = [s.Pending;adc];
            good = [s.PendingValid;repmat(~broken,numel(adc),1)];
            s.Received = s.Received+numel(adc);
            nFrames = floor(numel(x)/s.FrameSamples);
            used = s.FrameSamples*nFrames;
            if nFrames > 0
                frames = reshape(x(1:used),s.FrameSamples,nFrames);
                frames = frames-mean(frames,1);
                rmsValues = sqrt(mean(frames.^2,1)).';
                validFrames = all(reshape(good(1:used),s.FrameSamples,nFrames),1).';
                first = s.NextSample+(0:nFrames-1).'*s.FrameSamples;
                last = first+s.FrameSamples-1;
                rows = [first,last,(first-1)/s.Fs,last/s.Fs, ...
                    rmsValues,double(validFrames), ...
                    repmat(s.Segment,nFrames,1), ...
                    repmat(double(readGameTime),nFrames,1)];
                required = s.Count+nFrames;
                if required > size(s.Rows,1)
                    capacity = 512*ceil(required/512);
                    s.Rows(capacity,8) = 0;
                end
                s.Rows(s.Count+1:required,:) = rows;
                s.Count = required;
                s.NextSample = s.NextSample+used;
            end
            s.Pending = x(used+1:end);
            s.PendingValid = good(used+1:end);

        case "finish"
            if isempty(s)
                return;
            end
            if s.Reported
                report = s.Report;
                return;
            end
            rawBytesRemaining = varargin{1};
            publish = true;
            expected = NaN;
            if numel(varargin) >= 2
                publish = varargin{2};
            end
            if numel(varargin) >= 3
                expected = varargin{3};
            end
            frames = array2table(s.Rows(1:s.Count,:), ...
                'VariableNames',{'SampleFirst','SampleLast', ...
                'AudioStart_s','AudioEnd_s','RMS_ADC','Valid', ...
                'Segment','ReadGame_s'});
            frames.Valid = logical(frames.Valid);
            events = array2table(s.Events, 'VariableNames', ...
                {'BeforeSample','PreviousSeq','CurrentSeq','SequenceStep', ...
                'PreviousMissed','CurrentMissed','MissedTicksStep', ...
                'ResyncBytes','InvalidPackets','ReceiveErrors', ...
                'InitialBaselineUncertain'});
            events.InitialBaselineUncertain = ...
                logical(events.InitialBaselineUncertain);
            report = struct('Fs',s.Fs,'FrameSamples',s.FrameSamples, ...
                'Protocol',s.Protocol,'MissedTicksAvailable',s.MissedTicksAvailable, ...
                'Frames',frames,'Events',events, ...
                'ReceivedSamples',s.Received,'ProcessedSamples',s.FrameSamples*s.Count, ...
                'TailSamples',numel(s.Pending), ...
                'TailValid',all(s.PendingValid), ...
                'RawBytesRemaining',rawBytesRemaining, ...
                'PendingFaults',s.Faults, ...
                'FirstSequence',s.FirstSeq,'FirstMissedTicks',s.FirstMissed, ...
                'ExpectedReceivedSamples',expected);
            report.AccountingOK = ...
                s.Received == report.ProcessedSamples+report.TailSamples && ...
                s.NextSample == report.ProcessedSamples+1 && ...
                numel(s.PendingValid) == report.TailSamples && ...
                report.TailSamples < s.FrameSamples && ...
                (isnan(expected) || expected == s.Received);
            s.Reported = true;
            s.Report = report;
            if publish
                assignin('base','ENV20Log',report);
                fprintf(['ENV20 SUMMARY | Frames %d | Invalid %d | ' ...
                    'Events %d | Tail %d | AccountingOK %d\n'], ...
                    s.Count,sum(~frames.Valid),height(events), ...
                    report.TailSamples,report.AccountingOK);
                fprintf(['ENV20Log saved to workspace | Pending faults ' ...
                    '[resync invalid receive]: %.0f %.0f %.0f | ' ...
                    'RawBytesRemaining %.0f\n'],s.Faults,rawBytesRemaining);
            end

        otherwise
            error('rhythmTransportDiagnostics:Action','Unknown action: %s',string(action));
    end
end
