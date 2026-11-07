classdef PitchDiagnosticRecorder < handle
    % In-memory observations only. Saves once, after Serial has been released.
    properties (SetAccess = private)
        Meta
        OutputFile
        Report = []
        Finished = false
        Saved = false
        ReceivedSamples = 0
        RawCount = 0
        PacketCount = 0
        PitchCount = 0
        SchedulerCount = 0
    end
    properties (Access = private)
        RawBuffer
        PacketRows = zeros(256,16)
        PitchRows = cell(256,1)
        Curves = cell(256,1)
        SchedulerRows = zeros(512,7)
        Errors = strings(0,1)
        Publish = true
    end
    methods
        function obj = PitchDiagnosticRecorder(config)
            root = fileparts(mfilename('fullpath'));
            label = "unlabelled";
            if evalin('base','exist(''YINExperimentLabel'',''var'') == 1')
                value = evalin('base','YINExperimentLabel');
                if (ischar(value) || isstring(value)) && isscalar(string(value))
                    label = string(value);
                end
            end
            if isfield(config,'ExperimentLabel'), label = string(config.ExperimentLabel); end
            folder = fullfile(root,'diagnostics_yin');
            if isfield(config,'OutputDir'), folder = config.OutputDir; end
            if isfield(config,'Publish'), obj.Publish = config.Publish; end
            seconds = min(max(config.ExpectedDuration_s+2,2),120);
            if isfield(config,'MaxCaptureSeconds'), seconds = config.MaxCaptureSeconds; end
            capacity = ceil(seconds*config.Fs/config.BlockSize)*config.BlockSize;
            obj.RawBuffer = zeros(capacity,1,'uint16');
            stamp = char(datetime('now','TimeZone','Asia/Bangkok','Format','yyyyMMdd_HHmmss_SSS'));
            [~,token] = fileparts(tempname(root));
            safeLabel = regexprep(char(label),'[^a-zA-Z0-9_-]','_');
            safeLabel = safeLabel(1:min(numel(safeLabel),40));
            obj.OutputFile = fullfile(folder,['YIN_' stamp '_' safeLabel '_' token '.mat']);
            obj.Meta = config;
            obj.Meta.SchemaVersion = 2;
            obj.Meta.MissedTicksAvailable = config.Fs==10000;
            obj.Meta.ExperimentLabel = label;
            obj.Meta.StartTimeBangkok = stamp;
            obj.Meta.RawCapacitySamples = capacity;
            obj.Meta.RawCapacityNominalSeconds = capacity/config.Fs;
            obj.Meta.TimeConvention = "Audio is accepted-sample index/Fs; Game fields are host observations, not synchronized capture times.";
            obj.Meta.MissingNumericValues = "NaN means not reached/not available; hypothetical interpolation is explicitly flagged.";
            obj.Meta.DetectorPath = string(which('detectLivePitch'));
            obj.Meta.DetectorSource = fileread(which('detectLivePitch'));
            obj.Meta.AppSource = fileread(config.AppFile);
        end

        function addPacket(obj,packet,adc,readGame,env)
            if obj.Finished, return; end
            first = obj.ReceivedSamples+1;
            last = obj.ReceivedSamples+numel(adc);
            meta = rhythmPacketMetadata(packet,obj.Meta.Fs);
            seq = meta.Sequence;
            missed = meta.MissedTicks;
            seqStep = NaN; missedStep = NaN;
            if obj.PacketCount > 0
                seqStep = mod(seq-obj.PacketRows(obj.PacketCount,6),2^32);
                if isfinite(missed) && isfinite(obj.PacketRows(obj.PacketCount,7))
                    missedStep = mod(missed-obj.PacketRows(obj.PacketCount,7),2^32);
                end
            end
            broken = ~isempty(env.Events) && env.Events(end,1) == first;
            faults = [0 0 0];
            if broken, faults = env.Events(end,8:10); end
            stored = numel(adc) <= numel(obj.RawBuffer)-obj.RawCount;
            rawFirst = NaN; rawLast = NaN;
            if stored
                rawFirst = obj.RawCount+1;
                rawLast = obj.RawCount+numel(adc);
                obj.RawBuffer(rawFirst:rawLast) = uint16(adc(:));
                obj.RawCount = rawLast;
            end
            obj.PacketCount = obj.PacketCount+1;
            if obj.PacketCount > size(obj.PacketRows,1)
                obj.PacketRows(end+256,16) = 0;
            end
            obj.PacketRows(obj.PacketCount,:) = [first,last, ...
                (first-1)/obj.Meta.Fs,last/obj.Meta.Fs,readGame,seq,missed, ...
                seqStep,missedStep,env.Segment,double(~broken),rawFirst,rawLast, ...
                faults];
            obj.ReceivedSamples = last;
        end

        function addScheduler(obj,t,nSamples,lastPitch,blocks,lastBlocks)
            if obj.Finished, return; end
            obj.SchedulerCount = obj.SchedulerCount+1;
            if obj.SchedulerCount > size(obj.SchedulerRows,1)
                obj.SchedulerRows(end+512,7) = 0;
            end
            obj.SchedulerRows(obj.SchedulerCount,:) = [t,nSamples,t-lastPitch,blocks, ...
                nSamples >= 2048,t-lastPitch >= 0.15,blocks ~= lastBlocks];
        end

        function addPitch(obj,trace,context)
            if obj.Finished, return; end
            curve = trace.CMNDFCurve;
            trace = rmfield(trace,'CMNDFCurve');
            names = fieldnames(context);
            for j = 1:numel(names), trace.(names{j}) = context.(names{j}); end
            first = context.AudioSampleLast-2048+1;
            last = context.AudioSampleLast;
            trace.AudioSampleFirst = first;
            trace.AudioStart_s = (first-1)/obj.Meta.Fs;
            trace.AudioEnd_s = last/obj.Meta.Fs;
            p = obj.PacketRows(1:obj.PacketCount,:);
            overlaps = p(:,1) <= last & p(:,2) >= first;
            trace.WindowContinuityValid = first >= 1 && any(overlaps) && ...
                all(p(overlaps,11) == 1) && numel(unique(p(overlaps,10))) == 1 && ...
                p(find(overlaps,1),1) <= first && p(find(overlaps,1,'last'),2) >= last;
            trace.RawWindowCaptured = first >= 1 && last <= obj.RawCount;
            trace.LastPacketReadGame_s = NaN;
            if ~isempty(p), trace.LastPacketReadGame_s = p(end,5); end
            trace.ObservedReadOffset_s = trace.LastPacketReadGame_s-trace.AudioEnd_s;
            obj.PitchCount = obj.PitchCount+1;
            if obj.PitchCount > numel(obj.PitchRows)
                obj.PitchRows{end+256,1} = [];
                obj.Curves{end+256,1} = [];
            end
            obj.PitchRows{obj.PitchCount} = trace;
            obj.Curves{obj.PitchCount} = curve;
        end

        function recordError(obj,error)
            obj.Errors(end+1,1) = string(error.identifier)+": "+string(error.message);
        end

        function report = finish(obj,envReport,expectedSamples,stopReason)
            if isempty(obj.Report)
                report = struct;
                report.Meta = obj.Meta;
                report.Meta.StopReason = string(stopReason);
                report.Meta.OutputFile = string(obj.OutputFile);
                report.Packets = array2table(obj.PacketRows(1:obj.PacketCount,:), ...
                    'VariableNames',{'SampleFirst','SampleLast','AudioStart_s','AudioEnd_s', ...
                    'ReadGame_s','Sequence','CumulativeMissedTicks','SequenceStep', ...
                    'MissedTicksStep','Segment','ContinuityValid','RawFirst','RawLast', ...
                    'ResyncBytes','InvalidPackets','ReceiveErrors'});
                report.Packets.ContinuityValid = logical(report.Packets.ContinuityValid);
                report.Scheduler = array2table(obj.SchedulerRows(1:obj.SchedulerCount,:), ...
                    'VariableNames',{'GameUpdate_s','RecentSampleCount','SinceLastPitch_s', ...
                    'BlocksReceived','EnoughSamples','IntervalReady','NewBlock'});
                report.Scheduler.ShouldRun = all(report.Scheduler{:,5:7} ~= 0,2);
                report.Pitch = table;
                if obj.PitchCount > 0
                    report.Pitch = struct2table(vertcat(obj.PitchRows{1:obj.PitchCount}));
                end
                report.CMNDFCurves = obj.Curves(1:obj.PitchCount);
                report.RawADC = obj.RawBuffer(1:obj.RawCount);
                report.RawADC_GlobalSampleFirst = 1;
                report.ReceivedSamples = obj.ReceivedSamples;
                report.RawStoredSamples = obj.RawCount;
                report.RawNotStoredSamples = obj.ReceivedSamples-obj.RawCount;
                report.RawCaptureTruncated = report.RawNotStoredSamples > 0;
                report.PitchChecksExpected = sum(report.Scheduler.ShouldRun);
                report.PitchChecksRecorded = obj.PitchCount;
                report.DiagnosticChecksComplete = isempty(obj.Errors) && ...
                    report.PitchChecksExpected == report.PitchChecksRecorded;
                report.ExpectedReceivedSamples = expectedSamples;
                report.AccountingOK = obj.ReceivedSamples == expectedSamples && ...
                    sum(report.Packets.SampleLast-report.Packets.SampleFirst+1) == expectedSamples;
                report.LoggerErrors = obj.Errors;
                report.ENV20 = envReport;
                obj.Report = report;
                obj.Finished = true;
            else
                report = obj.Report;
            end
            if obj.Publish
                assignin('base','YINDiagnostic',report);
                assignin('base','YINDiagnosticFile',obj.OutputFile);
            end
            if ~obj.Saved
                folder = fileparts(obj.OutputFile);
                if ~isfolder(folder), mkdir(folder); end
                PitchDiagnostic = report; %#ok<NASGU>
                save(obj.OutputFile,'PitchDiagnostic','-v7');
                obj.Saved = true;
                if obj.Publish
                    fprintf('YIN_DIAGNOSTIC_SAVED | %s\n',obj.OutputFile);
                    fprintf('YIN SUMMARY | Pitch calls %d | Raw samples %d | AccountingOK %d | Logger errors %d\n', ...
                        obj.PitchCount,obj.RawCount,report.AccountingOK,numel(obj.Errors));
                end
            end
        end
    end
end
