classdef AudioRhythmGame < matlab.apps.App

    % Used to locate and load the app's XML configuration file
    properties (Access = public, Constant)
        AppConfigFilename = './AudioRhythmGame.xml'; % File path to the app configuration file containing component layout and settings
    end

    % Properties that correspond to app components
    properties (Access = public)
        UIFigure                        matlab.ui.Figure
        StatusLabel                     matlab.ui.control.Label
        FrequencyLabel                  matlab.ui.control.Label
        DetectedNoteLabel               matlab.ui.control.Label
        PitchCaptionLabel               matlab.ui.control.Label
        SubtitleLabel                   matlab.ui.control.Label
        TitleLabel                      matlab.ui.control.Label
        JudgementLabel                  matlab.ui.control.Label
        MissLabel                       matlab.ui.control.Label
        HitLabel                        matlab.ui.control.Label
        SongLabel                       matlab.ui.control.Label
        ScoreLabel                      matlab.ui.control.Label
        CurrentNoteLabel                matlab.ui.control.Label
        ComboLabel                      matlab.ui.control.Label
        StopButton                      matlab.ui.control.Button
        StartGameButton                 matlab.ui.control.Button
        LoadCSVButton                   matlab.ui.control.Button
        GameAxes                        matlab.ui.control.UIAxes
    end

    

    properties (Access = private)
        Beatmap = table()
        BeatmapPath = ""

        % Falling Notes Game
        GameTimer = []
        GameClock = []
        IsPlaying = false

        LeadTime = 6.0 % Visual only; CSV judgement times remain unchanged.

        NoteRects = []
        NoteTexts = []

        % ESP32 Live Audio Streaming
        SerialObj = []
        RawBytes = uint8([])
        AudioRecent = []
        % Continuous ENV20 diagnostics, independent of note judgment
        TransportDiagnostics = []
        PitchRecorder = []

        BlocksReceived = 0

        Fs = 10000
        BlockSize = 1024
        PacketSize = 2060
        AudioProtocol = "legacy"
        TransportStats = []

        % Live Pitch Detection
        LastPitchTime = -Inf
        LastPitchBlockCount = -1
        % Stable Pitch Detection
        RecentPitchNotes = strings(1,3)


        % Rhythm Judgment
        Score = 0
        Combo = 0
        JudgedNotes = false(0,1)
        ScoreState = []
        % STEP7A persistence only; never used by pitch/scoring decisions.
        ScoreExportAttempted = false
        ScoreExportSession = ""

        % Onset Detection
        LastOnsetTime = -Inf
        OnsetThreshold = 95
        OnsetMinGap = 0.20

        % Real-time Spectral Flux State
        FluxNextEndSample = 512
        FluxPrevMag = []
        FluxOlder = 0
        FluxMiddle = 0
        FluxMiddleSample = 0

        % Last pitch-confirmed onset
        LastConfirmedOnsetTime = -Inf

        % Prevent repeated confirmation of a held note
        LastConfirmedPitchNote = ""
        NoPitchCount = 0

        LastOnsetGameTime = -Inf

        % UI presentation state only; never used by note/score decisions.
        UIEventCount = 0
        UIFeedbackUntil = -Inf
        UIHasFinalResult = false
        UIFinalSnapshot = []
        UILastValidNote = '---'
        UILastValidFrequency = '--- Hz' 

        end

 

    
    methods (Access = private)

        
        function syncScore(app)
            if isempty(app.ScoreState), return; end
            app.Score = app.ScoreState.Score;
            app.Combo = app.ScoreState.Combo;
            app.JudgedNotes = app.ScoreState.Outcome ~= "OPEN";
            app.ScoreLabel.Text = sprintf('%d',app.Score);
            app.ComboLabel.Text = sprintf('%d',app.Combo);
            % UI PRESENTATION BEGIN
            % Hide only scorer-confirmed rows; row indices address both graphics arrays.
            hitRows = find(app.ScoreState.Outcome == "HIT");
            for row = hitRows(:).'
                if row <= numel(app.NoteRects) && isgraphics(app.NoteRects(row))
                    app.NoteRects(row).Visible = 'off';
                end
                if row <= numel(app.NoteTexts) && isgraphics(app.NoteTexts(row))
                    app.NoteTexts(row).Visible = 'off';
                end
            end
            app.HitLabel.Text = sprintf('Hit: %d',sum(app.ScoreState.Outcome == "HIT"));
            app.MissLabel.Text = sprintf('Miss: %d',sum(app.ScoreState.Outcome == "MISS"));
            events = app.ScoreState.Events;
            if numel(events) > app.UIEventCount
                event = events(end);
                switch event.Kind
                    case "HIT"
                        showHitGradeUI(app,app.ScoreState.Events(end));
                    case "MISS"
                        app.JudgementLabel.Text = 'MISS';
                        styleRhythmJudgement(app.JudgementLabel);
                    case "WRONG"
                        app.JudgementLabel.Text = 'WRONG NOTE';
                        styleRhythmJudgement(app.JudgementLabel);
                    otherwise
                        app.JudgementLabel.Text = 'CHECK AUDIO';
                        styleRhythmJudgement(app.JudgementLabel);
                end
                app.UIFeedbackUntil = event.Game_s + 0.70;
                app.UIEventCount = numel(events);
            end
            % UI PRESENTATION END

        end

        function exportFinalScoreEvidence(app,endReason)
            % Runs only after timer/serial cleanup. No gameplay state is changed.
            if app.ScoreExportAttempted || isempty(app.ScoreState) || ~app.ScoreState.Reported
                return;
            end
            app.ScoreExportAttempted = true; % At most one attempt per session, even on failure.
            try
                meta = struct('SessionID',app.ScoreExportSession, ...
                    'Beatmap',app.BeatmapPath,'EndReason',string(endReason), ...
                    'RuntimeFile',[mfilename('fullpath') '.m']);
                if ~isempty(app.PitchRecorder)
                    meta.SessionStartBangkok = app.PitchRecorder.Meta.StartTimeBangkok;
                    meta.DiagnosticFile = string(app.PitchRecorder.OutputFile);
                end
                result = exportRhythmScore(app.ScoreState,meta);
                assignin('base','RhythmScoreExportStatus',result);
                if result.Success
                    fprintf('SCORE CSV | %s\n',result.File);
                else
                    warning('RhythmGame:ScoreExport','Score CSV export failed: %s',result.Error);
                end
            catch exportError
                failure = struct('Success',false,'AlreadyExists',false,'File',"", ...
                    'SessionID',app.ScoreExportSession,'Error',string(exportError.message));
                assignin('base','RhythmScoreExportStatus',failure);
                warning('RhythmGame:ScoreExport','Score CSV export failed: %s',exportError.message);
            end
        end

        function showHitGradeUI(app,event)
            % Display only the grade already accepted by the scorer.
            app.JudgementLabel.Text = char(event.Grade);
            switch event.Grade
                case "PERFECT"
                    styleRhythmJudgement(app.JudgementLabel);
                case "GREAT"
                    styleRhythmJudgement(app.JudgementLabel);
                case "GOOD"
                    styleRhythmJudgement(app.JudgementLabel);
            end
        end

        function holdFinalResultsUI(app,statusText)
            % A display snapshot of the finished round, never score input.
            if app.UIHasFinalResult
                restoreFinalResultsUI(app);
                return;
            end
            if isempty(app.GameClock), return; end
            app.DetectedNoteLabel.Text = app.UILastValidNote;
            app.FrequencyLabel.Text = app.UILastValidFrequency;
            app.PitchCaptionLabel.Text = 'LAST DETECTED NOTE';
            app.StatusLabel.Text = statusText;
            app.StatusLabel.FontColor = [0.568627450980392 0.643137254901961 0.72156862745098];
            if ~isempty(app.ScoreState) && ~isempty(app.ScoreState.Events)
                switch app.ScoreState.Events(end).Kind
                    case "HIT"
                        showHitGradeUI(app,app.ScoreState.Events(end));
                    case "MISS"
                        app.JudgementLabel.Text = 'MISS';
                        styleRhythmJudgement(app.JudgementLabel);
                    case "WRONG"
                        app.JudgementLabel.Text = 'WRONG NOTE';
                        styleRhythmJudgement(app.JudgementLabel);
                    otherwise
                        app.JudgementLabel.Text = 'CHECK AUDIO';
                        styleRhythmJudgement(app.JudgementLabel);
                end
            end
            app.UIFinalSnapshot = struct( ...
                'Score',app.ScoreLabel.Text,'Combo',app.ComboLabel.Text, ...
                'Hit',app.HitLabel.Text,'Miss',app.MissLabel.Text, ...
                'Note',app.DetectedNoteLabel.Text,'Frequency',app.FrequencyLabel.Text, ...
                'Status',app.StatusLabel.Text,'Feedback',app.JudgementLabel.Text, ...
                'FeedbackColor',app.JudgementLabel.FontColor);
            app.UIHasFinalResult = true;
            app.ScoreLabel.Tooltip = 'Final result of the last round; Start Game resets it';
        end

        function restoreFinalResultsUI(app)
            if ~app.UIHasFinalResult || isempty(app.UIFinalSnapshot), return; end
            v = app.UIFinalSnapshot;
            app.ScoreLabel.Text = v.Score;
            app.ComboLabel.Text = v.Combo;
            app.HitLabel.Text = v.Hit;
            app.MissLabel.Text = v.Miss;
            app.DetectedNoteLabel.Text = v.Note;
            app.FrequencyLabel.Text = v.Frequency;
            app.PitchCaptionLabel.Text = 'LAST DETECTED NOTE';
            app.StatusLabel.Text = v.Status;
            app.StatusLabel.FontColor = [0.568627450980392 0.643137254901961 0.72156862745098];
            app.JudgementLabel.Text = v.Feedback;
            styleRhythmJudgement(app.JudgementLabel);
        end

        function results = prepareGame(app)

                results = [];
                ax = app.GameAxes;
                cla(ax);

                % Configure game area
                ax.XLim = [0.5 7.5];
                ax.YLim = [0 100];
                ax.XTick = [];
                ax.YTick = [];
                ax.Color = [0.0313725490196078 0.0509803921568627 0.0901960784313725];
                ax.FontName = 'Bahnschrift';
                ax.Box = 'on';
                ax.Toolbar.Visible = 'off';
                disableDefaultInteractivity(ax);

                title(ax,'');
                xlabel(ax,'');
                ylabel(ax,'');

                hold(ax,'on');

                % Draw seven lanes
                names = {'C4','D4','E4','F4', ...
                    'G4','A4','B4'};

                for k = 1:7

                    if mod(k,2) == 0
                        bg = [0.0627450980392157 0.105882352941176 0.164705882352941];
                    else
                        bg = [0.0313725490196078 0.0509803921568627 0.0901960784313725];
                    end

                    rectangle(ax,'Position', ...
                        [k-0.5 0 1 100], ...
                        'FaceColor',bg, ...
                        'EdgeColor',[0.149019607843137 0.223529411764706 0.301960784313725]);

                    text(ax,k,96,names{k}, ...
                        'HorizontalAlignment','center', ...
                        'Color',[0.941176470588235 0.956862745098039 0.972549019607843], ...
                        'FontName','Bahnschrift', ...
                        'FontWeight','bold');
                end

                % Visual judgement zone only. Lower edge remains the
                % original y=15 anchor; no score window uses these bounds.
                zoneHeight = max(10,72 * 0.30 / app.LeadTime);
                if ~isempty(app.Beatmap)
                    % One fixed zone per beatmap, large enough for every note.
                    zoneHeight = max(max(10, ...
                        72 * app.Beatmap.Duration_s / app.LeadTime));
                end
                zoneBottom = 15;
                zoneTop = zoneBottom + zoneHeight;
                patch(ax,[0.5 7.5 7.5 0.5], ...
                    [zoneBottom zoneBottom zoneTop zoneTop], ...
                    [0.0862745098039216 0.850980392156863 0.92156862745098],'FaceAlpha',0.14,'EdgeColor','none', ...
                    'Tag','JudgementZoneFill','HitTest','off');
                line(ax,[0.5 7.5],[zoneBottom zoneBottom], ...
                    'Color',[0.0862745098039216 0.850980392156863 0.92156862745098],'LineWidth',3.5, ...
                    'Tag','JudgementZoneLower','HitTest','off');
                line(ax,[0.5 7.5],[zoneTop zoneTop], ...
                    'Color',[0.0862745098039216 0.850980392156863 0.92156862745098],'LineWidth',3.5, ...
                    'Tag','JudgementZoneUpper','HitTest','off');

                % Prepare falling note objects
                T = app.Beatmap;
                N = height(T);

                app.NoteRects = gobjects(N,1);
                app.NoteTexts = gobjects(N,1);

                allowed = [60 62 64 65 67 69 71];

                for i = 1:N

                    lane = find(allowed == T.MIDI(i),1);

                    app.NoteRects(i) = rectangle(ax, ...
                        'Position',[lane-0.4 90 0.8 5], ...
                        'FaceColor',[0.0862745098039216 0.850980392156863 0.92156862745098], ...
                        'EdgeColor',[0.0862745098039216 0.850980392156863 0.92156862745098], ...
                        'Curvature',[0.22 0.45], ...
                        'LineWidth',1.5, ...
                        'Visible','off');

                    app.NoteTexts(i) = text(ax,lane,90, ...
                        names{lane}, ...
                        'HorizontalAlignment','center', ...
                        'Color',[0.941176470588235 0.956862745098039 0.972549019607843], ...
                        'FontName','Bahnschrift', ...
                        'FontWeight','bold', ...
                        'Visible','off');
                end

                hold(ax,'off');

        end
        
        function results = updateGame(app)

                results = [];

                if ~app.IsPlaying
                    return;
                end


                t = toc(app.GameClock);

                % Receive ESP32 Audio
                receiveAudioBlocks(app);

                % SCORE RULES BEGIN
                app.ScoreState = rhythmScore("advance",app.ScoreState,t);
                syncScore(app);
                % SCORE RULES END

                % ======================================
                % REAL-TIME SPECTRAL FLUX
                % ======================================

                Nfft = 512;
                hop = 128;

                x = double(app.AudioRecent(:));

                totalSamples = app.BlocksReceived * app.BlockSize;
                firstGlobal = totalSamples - numel(x) + 1;

                if numel(x) >= Nfft

                    w = 0.5 - 0.5*cos( ...
                        2*pi*(0:Nfft-1)'/(Nfft-1));

                    while app.FluxNextEndSample <= totalSamples

                        frameStart = app.FluxNextEndSample - Nfft + 1;
                        localStart = frameStart - firstGlobal + 1;

                        if localStart < 1 || ...
                                localStart+Nfft-1 > numel(x)

                            app.FluxNextEndSample = ...
                                app.FluxNextEndSample + hop;

                            app.FluxPrevMag = [];
                            app.FluxOlder = 0;
                            app.FluxMiddle = 0;

                            continue;
                        end

                        frame = x(localStart:localStart+Nfft-1);
                        frame = frame - mean(frame);

                        X = fft(frame.*w);
                        mag = log1p(abs(X(1:Nfft/2+1)));

                        fluxValue = 0;

                        if ~isempty(app.FluxPrevMag)
                            fluxValue = sum(max( ...
                                0,mag-app.FluxPrevMag));
                        end

                        app.FluxPrevMag = mag;

                        % Detect local maximum
                        isPeak = ...
                            app.FluxMiddle > app.FluxOlder && ...
                            app.FluxMiddle >= fluxValue && ...
                            app.FluxMiddle >= app.OnsetThreshold;

                        % Temporary Flux diagnostic near E4 notes
                        isLocalPeak = ...
                            app.FluxMiddle > app.FluxOlder && ...
                            app.FluxMiddle >= fluxValue;


                        if isLocalPeak && app.FluxMiddle >= 70 && ...
                                ((t >= 1.7 && t <= 2.6) || ...
                                (t >= 3.6 && t <= 4.5))

                            fprintf(['FLUX TEST | Game %.2f | ' ...
                                'AudioOnset %.3f | Flux %.1f | Pass %d\n'], ...
                                t, ...
                                (app.FluxMiddleSample-Nfft/2)/app.Fs, ...
                                app.FluxMiddle, isPeak);
                        end


                        if isPeak

                            onsetT = ...
                                (app.FluxMiddleSample-Nfft/2)/app.Fs;

                            if onsetT >= 0 && ...
                                    onsetT-app.LastOnsetTime >= app.OnsetMinGap

                                app.LastOnsetTime = onsetT;

                                audioNowAtOnset = ...
                                    app.BlocksReceived * app.BlockSize / app.Fs;

                                app.LastOnsetGameTime = ...
                                    onsetT + (t - audioNowAtOnset);


                                % Debug accepted onset
                                fprintf('ONSET ACCEPT | Game %.3f | AudioOnset %.3f\n', ...
                                    t, onsetT);

                            end
                        end

                        app.FluxOlder = app.FluxMiddle;
                        app.FluxMiddle = fluxValue;

                        app.FluxMiddleSample = ...
                            app.FluxNextEndSample;

                        app.FluxNextEndSample = ...
                            app.FluxNextEndSample + hop;

                    end
                end


                % YIN DIAGNOSTIC BEGIN
                if ~isempty(app.PitchRecorder)
                    try
                        app.PitchRecorder.addScheduler(t,numel(app.AudioRecent), ...
                            app.LastPitchTime,app.BlocksReceived,app.LastPitchBlockCount);
                    catch diagnosticError
                        app.PitchRecorder.recordError(diagnosticError);
                    end
                end
                % YIN DIAGNOSTIC END

                % Live YIN Pitch Detection
                if numel(app.AudioRecent) >= 2048 && ...
                        t - app.LastPitchTime >= 0.15 && ...
                        app.BlocksReceived ~= app.LastPitchBlockCount

                    % YIN DIAGNOSTIC BEGIN
                    yinStartGame = toc(app.GameClock);
                    yinLockBefore = app.LastConfirmedPitchNote;
                    yinNoPitchBefore = app.NoPitchCount;
                    % YIN DIAGNOSTIC END
                    [noteName,f0,conf,rmsADC,yinTrace] = ...
                        detectLivePitch(app.AudioRecent,app.Fs,30);
                    % YIN DIAGNOSTIC BEGIN
                    yinEndGame = toc(app.GameClock);
                    % YIN DIAGNOSTIC END

                    % ===== STABLE PITCH CHECK =====
                    app.RecentPitchNotes = ...
                        [app.RecentPitchNotes(2:3), string(noteName)];

                    isStablePitch = ...
                        isfinite(f0) && ...
                        string(noteName) ~= "---" && ...
                        sum(app.RecentPitchNotes == string(noteName)) >= 2;

                    % Temporary E4-band energy diagnostic
                    if t >= 3.5 && t <= 6.1

                        nBand = 2048;
                        z = double(app.AudioRecent(end-nBand+1:end));
                        z = z - mean(z);

                        Z = fft(z);
                        hz = (0:nBand-1)' * app.Fs / nBand;

                        e4Mask = ...
                            (hz >= 300 & hz <= 360) | ...
                            (hz >= app.Fs-360 & hz <= app.Fs-300);

                        e4Signal = real(ifft(Z .* double(e4Mask)));
                        e4RMS = sqrt(mean(e4Signal.^2));

                        fprintf(['E4 ENERGY | Game %.3f | ' ...
                            'Pitch %s | RMS %.1f | E4Band %.1f\n'], ...
                            t, char(noteName), rmsADC, e4RMS);
                    end


                    % Rearm after two consecutive no-pitch results
                    if app.LastConfirmedPitchNote ~= ""

                        if string(noteName) == "---"
                            app.NoPitchCount = app.NoPitchCount + 1;

                            if app.NoPitchCount >= 4
                                app.LastConfirmedPitchNote = "";
                                app.NoPitchCount = 0;


                                fprintf('PITCH REARM | Game %.3f | RMS %.1f\n', ...
                                    t, rmsADC);

                            end
                        else
                            app.NoPitchCount = 0;
                        end
                    end


                    % Debug accepted YIN pitch
                    if isfinite(f0)
                        fprintf(['PITCH VALID | Game %.2f | Note %s | ' ...
                            'Freq %.2f | Conf %.3f | Stable %d\n'], ...
                            t, char(noteName), f0, conf, isStablePitch);
                    end


                    % Debug stable note in the game
                    if isStablePitch
                        fprintf('GAME STABLE | Note %s | Freq %.2f Hz | Conf %.3f\n', ...
                            char(noteName), f0, conf);
                    end

                    % Show diagnostic status about once per second

                    % Show diagnostic status about once per second
                    if floor(t) > floor(app.LastPitchTime)
                        fprintf(['STATUS | Game %.2f s | Blocks %d | ' ...
                            'Note %s | RMS %.1f | LastFlux %.3f\n'], ...
                            t, app.BlocksReceived, ...
                            char(noteName), rmsADC, app.LastOnsetTime);
                    end

                    app.LastPitchTime = t;
                    app.LastPitchBlockCount = app.BlocksReceived;


                    % Confirm Flux Candidate using YIN
                    audioTime = app.BlocksReceived * ...
                        app.BlockSize / app.Fs;

                    dt = audioTime - app.LastOnsetTime;

                    % Check whether the detected note matches the beatmap

                    % Find closest unjudged note in beatmap
                    estimatedGameOnset = app.LastOnsetGameTime;
                    isBeatmapMatch = false;
                    matchedNoteIdx = [];

                    if isfinite(app.LastOnsetTime)

                        noteMatch = ...
                            string(app.Beatmap.Note) == string(noteName);

                        timeError = abs( ...
                            app.Beatmap.StartTime_s - estimatedGameOnset);

                        candidates = find( ...
                            noteMatch & ...
                            timeError <= 0.35 & ...
                            ~app.JudgedNotes);

                        if ~isempty(candidates)

                            [~,j] = min(timeError(candidates));
                            matchedNoteIdx = candidates(j);

                            isBeatmapMatch = true;
                        end
                    end


                    

                    % Debug timing between stable pitch and onset
                    if isStablePitch && isfinite(app.LastOnsetTime)
                        fprintf(['TIMING CHECK | Game %.3f | Note %s | ' ...
                            'AudioNow %.3f | Onset %.3f | dt %.3f\n'], ...
                            t, char(noteName), audioTime, ...
                            app.LastOnsetTime, dt);
                    end


        

                    % YIN DIAGNOSTIC BEGIN
                    yinJudgment = pitchDecisionDiagnostic(noteName,f0,conf,isStablePitch, ...
                        app.RecentPitchNotes,isBeatmapMatch,matchedNoteIdx, ...
                        app.LastOnsetTime,app.LastConfirmedOnsetTime,dt,app.LastConfirmedPitchNote);
                    yinJudgment.GameUpdate_s = t;
                    yinJudgment.DetectionStartGame_s = yinStartGame;
                    yinJudgment.DetectionEndGame_s = yinEndGame;
                    yinJudgment.AudioSampleLast = app.BlocksReceived * app.BlockSize;
                    yinJudgment.BeatmapOnsetGameEstimate_s = app.LastOnsetGameTime;
                    yinJudgment.PitchLockBefore = yinLockBefore;
                    yinJudgment.NoPitchCountBefore = yinNoPitchBefore;
                    yinJudgment.NoPitchCountAtJudgment = app.NoPitchCount;
                    % YIN DIAGNOSTIC END

                    % SCORE RULES BEGIN
                    scoreEvidence = struct('Note',string(noteName),'F0',f0, ...
                        'Stable',isStablePitch,'Confidence',conf,'Game_s',t, ...
                        'OnsetAudio_s',app.LastOnsetTime,'OnsetGame_s',app.LastOnsetGameTime, ...
                        'Age_s',dt,'FreshOnset',app.LastOnsetTime>app.LastConfirmedOnsetTime, ...
                        'DifferentPitchFromLock',string(noteName)~=app.LastConfirmedPitchNote, ...
                        'AudioSampleFirst',app.BlocksReceived*app.BlockSize-2048+1, ...
                        'ContinuityValid',all(app.TransportDiagnostics.Faults==0));
                    % SCORE RULES END

                    % Temporary debug: detect same-note pitch lock
                    if isStablePitch && ...
                            conf >= 0.55 && ...
                            isBeatmapMatch && ...
                            string(noteName) == app.LastConfirmedPitchNote && ...
                            isfinite(app.LastOnsetTime) && ...
                            app.LastOnsetTime > app.LastConfirmedOnsetTime && ...
                            dt >= 0.10 && dt <= 0.75

                        fprintf(['LOCK BLOCK | Game %.3f | Row %d | ' ...
                            'Note %s | Onset %.3f | dt %.3f\n'], ...
                            t, matchedNoteIdx, char(noteName), ...
                            app.LastOnsetTime, dt);
                    end

                    if isStablePitch && ...
                            conf >= 0.55 && ...
                            isBeatmapMatch && ...
                            string(noteName) ~= app.LastConfirmedPitchNote && ...
                            isfinite(app.LastOnsetTime) && ...
                            app.LastOnsetTime > app.LastConfirmedOnsetTime && ...
                            dt >= 0.10 && dt <= 0.75



                        app.LastConfirmedOnsetTime = ...
                            app.LastOnsetTime;

                        app.LastConfirmedPitchNote = string(noteName);
                        app.NoPitchCount = 0;


                        % Mark matched beatmap note as used
                        app.JudgedNotes(matchedNoteIdx) = true;

                        % TASK3 SCORE BEGIN
                        app.ScoreState = rhythmScore("hit",app.ScoreState,matchedNoteIdx,scoreEvidence);
                        syncScore(app);
                        % TASK3 SCORE END

                        fprintf(['BEATMAP MATCH | Row %d | ' ...
                            'Target %.3f | Estimated %.3f | Error %+.3f s\n'], ...
                            matchedNoteIdx, ...
                            app.Beatmap.StartTime_s(matchedNoteIdx), ...
                            estimatedGameOnset, ...
                            estimatedGameOnset - ...
                            app.Beatmap.StartTime_s(matchedNoteIdx));


                        fprintf(['CONFIRMED | GameNow %.3f s | ' ...
                            'AudioNow %.3f s | Onset %.3f s | ' ...
                            'Note %s | %.1f Hz\n'], ...
                            t, audioTime, app.LastOnsetTime, ...
                            char(noteName), f0);


                        % Estimate onset position on game timeline
                        estimatedGameOnset = t - ...
                            (audioTime - app.LastOnsetTime);

                        fprintf('Estimated Game Onset: %.3f s\n', ...
                            estimatedGameOnset);


                    end


                    % SCORE RULES BEGIN
                    app.ScoreState = rhythmScore("wrong",app.ScoreState,scoreEvidence);
                    syncScore(app);
                    % SCORE RULES END

                    % YIN DIAGNOSTIC BEGIN
                    yinJudgment.ConfirmedThisAttempt = ...
                        app.LastConfirmedOnsetTime > yinJudgment.LastConfirmedOnsetBefore_s;
                    if ~isempty(app.PitchRecorder)
                        try
                            app.PitchRecorder.addPitch(yinTrace,yinJudgment);
                        catch diagnosticError
                            app.PitchRecorder.recordError(diagnosticError);
                        end
                    end
                    % YIN DIAGNOSTIC END

                    if isfinite(f0)
                        app.CurrentNoteLabel.Text = sprintf( ...
                            '%s | %.1f Hz',noteName,f0);
                    else
                        app.CurrentNoteLabel.Text = sprintf( ...
                            '--- | RMS: %.0f',rmsADC);
                    end
            % UI PRESENTATION BEGIN
            if isfinite(f0)
                app.DetectedNoteLabel.Text = char(noteName);
                app.FrequencyLabel.Text = sprintf('%.1f Hz',f0);
                app.UILastValidNote = app.DetectedNoteLabel.Text;
                app.UILastValidFrequency = app.FrequencyLabel.Text;
            else
                app.DetectedNoteLabel.Text = '---';
                app.FrequencyLabel.Text = '--- Hz';
            end
            % UI PRESENTATION END

                end

                T = app.Beatmap;
                N = height(T);

                allowed = [60 62 64 65 67 69 71];

                for i = 1:N

                    % A confirmed HIT stays hidden on every later frame.
                    if app.ScoreState.Outcome(i) == "HIT"
                        app.NoteRects(i).Visible = 'off';
                        app.NoteTexts(i).Visible = 'off';
                        continue;
                    end

                    lane = find(allowed == T.MIDI(i),1);

                    % Falling position
                    y = 15 + 72 * ...
                        (T.StartTime_s(i)-t)/app.LeadTime;

                    % Note length based on duration
                    noteHeight = max(10, ...
                        72*T.Duration_s(i)/app.LeadTime);

                    if y <= 100 && y+noteHeight >= 0

                        app.NoteRects(i).Position = ...
                            [lane-0.4 y 0.8 noteHeight];

                        app.NoteRects(i).Visible = 'on';

                        app.NoteTexts(i).Position = ...
                            [lane y+noteHeight/2 0];

                        app.NoteTexts(i).Visible = 'on';

                    else

                        app.NoteRects(i).Visible = 'off';
                        app.NoteTexts(i).Visible = 'off';

                    end
                end

            % UI PRESENTATION BEGIN
            if app.UIEventCount > 0 && t > app.UIFeedbackUntil
                app.JudgementLabel.Text = 'LISTENING';
                styleRhythmJudgement(app.JudgementLabel);
            end
            % UI PRESENTATION END
                drawnow limitrate;

                % End after last note passes the line
                endTime = max( ...
                    T.StartTime_s + T.Duration_s) + 0.9;
                % Allow the final MISS deadline plus two packet periods and one timer tick.
                endTime = max(endTime,max(T.StartTime_s)+1.10+2*app.BlockSize/app.Fs+.05);


                if t >= endTime
                    app.IsPlaying = false;

                    % Stop game timer
                    if ~isempty(app.GameTimer) && ...
                            isvalid(app.GameTimer)
                        stop(app.GameTimer);
                        delete(app.GameTimer);
                    end

                    app.GameTimer = [];

                    % Publish diagnostics after the timer has stopped.
                    app.TransportDiagnostics = rhythmTransportDiagnostics( ...
                        "finish", app.TransportDiagnostics, numel(app.RawBytes), ...
                        true, app.BlocksReceived * app.BlockSize);
                    app.TransportStats = finishRhythmTransport(app.TransportStats, ...
                        app.AudioProtocol,app.Fs,numel(app.RawBytes));

                    app.ScoreState = rhythmScore("finish",app.ScoreState,t);
                    syncScore(app);

                    % Release ESP32 COM port
                    if ~isempty(app.SerialObj)
                        try
                            if isvalid(app.SerialObj)
                                delete(app.SerialObj);
                            end
                        catch ME
                            warning('Serial cleanup: %s',ME.message);
                        end
                    end

                    app.SerialObj = [];

                    % YIN DIAGNOSTIC BEGIN
                    if ~isempty(app.PitchRecorder)
                        try
                            app.PitchRecorder.finish(app.TransportDiagnostics.Report, ...
                                app.BlocksReceived * app.BlockSize,"automatic_end");
                        catch diagnosticError
                            warning('YIN diagnostic save failed: %s',diagnosticError.message);
                        end
                    end
                    % YIN DIAGNOSTIC END

                    app.CurrentNoteLabel.Text = ...
                        'Animation Complete';
            % UI PRESENTATION BEGIN
            holdFinalResultsUI(app,'Complete');
            exportFinalScoreEvidence(app,"automatic_end");
            % UI PRESENTATION END

                end


        end
        
        function results = receiveAudioBlocks(app)

                results = [];

                % Check recording status
                if ~app.IsPlaying || isempty(app.SerialObj)
                    return;
                end

                try
                    % Check available serial bytes
                    n = app.SerialObj.NumBytesAvailable;

                    if n <= 0
                        return;
                    end

                    % Read incoming data
                    incoming = read(app.SerialObj,n,"uint8");

                    app.RawBytes = [app.RawBytes; ...
                        uint8(incoming(:))];

                    % Validate native packets before delivering any audio.
                    [decoded,app.RawBytes,batch] = ...
                        decodeRhythmPackets(app.RawBytes,app.AudioProtocol);
                    fields = {'AcceptedPackets','ResyncBytes','CRCFailures', ...
                        'BadHeaders','InvalidSamples'};
                    for fieldIndex = 1:numel(fields)
                        key = fields{fieldIndex};
                        app.TransportStats.(key) = app.TransportStats.(key)+batch.(key);
                    end
                    for packetIndex = 1:numel(decoded)
                        packet = decoded(packetIndex).Packet;
                        adc = decoded(packetIndex).ADC;
                        app.TransportDiagnostics.Faults = app.TransportDiagnostics.Faults+decoded(packetIndex).FaultsBefore;

                        % Store audio samples
                        app.AudioRecent = ...
                            [app.AudioRecent; adc(:)];

                        % Keep last 2 seconds
                        maxSamples = 2*app.Fs;

                        if numel(app.AudioRecent) > maxSamples

                            app.AudioRecent = ...
                                app.AudioRecent(end-maxSamples+1:end);
                        end

                        % Count valid blocks
                        app.BlocksReceived = app.BlocksReceived + 1;

                        % Process every accepted packet before the next one.
                        app.TransportDiagnostics = rhythmTransportDiagnostics( ...
                            "push", app.TransportDiagnostics, packet, adc, toc(app.GameClock));
                        broken = ~isempty(app.TransportDiagnostics.Events) && ...
                            app.TransportDiagnostics.Events(end,1)==app.TransportDiagnostics.Received-app.BlockSize+1;
                        app.ScoreState = rhythmScore("audio",app.ScoreState, ...
                            app.TransportDiagnostics.Received,toc(app.GameClock),broken);

                        % YIN DIAGNOSTIC BEGIN
                        if ~isempty(app.PitchRecorder)
                            try
                                app.PitchRecorder.addPacket(packet,adc,toc(app.GameClock),app.TransportDiagnostics);
                            catch diagnosticError
                                app.PitchRecorder.recordError(diagnosticError);
                            end
                        end
                        % YIN DIAGNOSTIC END

                    end
                    app.TransportDiagnostics.Faults = app.TransportDiagnostics.Faults+batch.PendingFaults;
                    if any(batch.PendingFaults~=0)
                        app.ScoreState = rhythmScore("fault",app.ScoreState);
                    end

                catch ME
                    if ~isempty(app.TransportDiagnostics)
                        app.TransportDiagnostics.Faults(3) = app.TransportDiagnostics.Faults(3) + 1;
                    end
                    if ~isempty(app.ScoreState)
                        app.ScoreState = rhythmScore("fault",app.ScoreState);
                    end
                    warning('ESP32 receive error: %s',ME.message);
                end

        end
    end
    

    % Callbacks that handle component events
    methods

        % Code that executes after component creation
        function startupFcn(app)
            configureRhythmUI(app);
            prepareGame(app);
        end

        % Button pushed function: LoadCSVButton
        function LoadCSVButtonPushed(app, event)

            if app.IsPlaying
                uialert(app.UIFigure,'Stop the game before loading another CSV.','Beatmap Error');
                return;
            end

            % Select CSV beatmap
            [file, path] = uigetfile( ...
                {'*.csv','CSV Beatmap Files'}, ...
                'Select Beatmap');

            if isequal(file,0)
                return;
            end

            try
                % Read CSV
                filename = fullfile(path,file);
                T = readtable(filename);

                T = validateRhythmBeatmap(T);

                % Store beatmap
                app.Beatmap = T;
                app.BeatmapPath = string(filename);
                app.Score = 0; app.Combo = 0; app.ScoreState = [];
                app.JudgedNotes = false(height(T),1);

                % Update GUI
                app.SongLabel.Text = file;
                app.ScoreLabel.Text = '0';
                app.ComboLabel.Text = '0';
            % UI PRESENTATION BEGIN
            app.UIEventCount = 0;
            app.UIFeedbackUntil = -Inf;
            app.HitLabel.Text = 'Hit: 0';
            app.MissLabel.Text = 'Miss: 0';
            app.JudgementLabel.Text = 'READY';
            styleRhythmJudgement(app.JudgementLabel);
            % UI PRESENTATION END

                app.CurrentNoteLabel.Text = ...
                    sprintf('Loaded: %d notes',height(T));
            % UI PRESENTATION BEGIN
            app.StatusLabel.Text = 'Ready';
            app.StatusLabel.FontColor = [0.568627450980392 0.643137254901961 0.72156862745098];
            app.DetectedNoteLabel.Text = '---';
            app.FrequencyLabel.Text = '--- Hz';
            if app.UIHasFinalResult
                restoreFinalResultsUI(app);
                app.SongLabel.Text = ['Next: ' file];
            end
            % UI PRESENTATION END


                % Command Window
                fprintf('\n===== BEATMAP LOADED =====\n');
                fprintf('File: %s\n',file);
                fprintf('Total Notes: %d\n',height(T));

                disp(T);

            catch ME
                uialert(app.UIFigure,ME.message, ...
                    'Beatmap Error');
            end

        end

        % Button pushed function: StartGameButton
        function StartGameButtonPushed(app, event)

            % Check if beatmap is loaded
            if isempty(app.Beatmap) || height(app.Beatmap)==0
                uialert(app.UIFigure, ...
                    'Please load a CSV first.', ...
                    'No Beatmap');
                return;
            end

            if app.IsPlaying
                return;
            end


            %% Connect ESP32

            try
                % Change COM port if necessary
                config = rhythmAudioConfig();
                port = config.Port;
                app.AudioProtocol = config.Protocol;
                app.Fs = config.Fs;
                app.PacketSize = config.PacketSize;
                app.TransportStats = struct('AcceptedPackets',0,'ResyncBytes',0, ...
                    'CRCFailures',0,'BadHeaders',0,'InvalidSamples',0,'Reported',false);

                app.SerialObj = serialport( ...
                    port,921600,"Timeout",1);

                flush(app.SerialObj);

                app.RawBytes = uint8([]);
                app.AudioRecent = [];
                app.BlocksReceived = 0;

                fprintf('ESP32 connected on %s\n',port);

            catch ME
                uialert(app.UIFigure,ME.message, ...
                    'ESP32 Connection Error');
                return;
            end


            % Prepare game screen
            prepareGame(app);


            % Reset Rhythm Judgment
            app.Score = 0;
            app.Combo = 0;
            app.JudgedNotes = false(height(app.Beatmap),1);
            app.ScoreState = rhythmScore("init",[],app.Beatmap,app.Fs);

            % Reset Onset Detection
            app.LastOnsetTime = -Inf;
            app.LastConfirmedOnsetTime = -Inf;
            % Start a fresh diagnostics session on every successful start.
            app.TransportDiagnostics = rhythmTransportDiagnostics("init", [], app.Fs);
            % YIN DIAGNOSTIC BEGIN
            diagnosticConfig = struct('Fs',app.Fs,'BlockSize',app.BlockSize, ...
                'ExpectedDuration_s',max(app.Beatmap.StartTime_s + app.Beatmap.Duration_s)+0.9, ...
                'BeatmapPath',app.BeatmapPath,'AppFile',[mfilename('fullpath') '.m'], ...
                'OnsetThreshold',app.OnsetThreshold,'OnsetMinGap',app.OnsetMinGap, ...
                'SerialClass',string(class(app.SerialObj)), ...
                'AudioProtocol',app.AudioProtocol);
            app.PitchRecorder = PitchDiagnosticRecorder(diagnosticConfig);
            app.ScoreExportAttempted = false;
            [~,sessionName] = fileparts(app.PitchRecorder.OutputFile);
            app.ScoreExportSession = string(sessionName);
            % YIN DIAGNOSTIC END
            % Reset Streaming Spectral Flux
            app.FluxNextEndSample = 512;
            app.FluxPrevMag = [];
            app.FluxOlder = 0;
            app.FluxMiddle = 0;
            app.FluxMiddleSample = 0;
            app.LastOnsetGameTime = -Inf;

            

            % Start game clock
            app.GameClock = tic;
            app.LastPitchTime = -Inf;
            app.LastPitchBlockCount = -1;

            % Reset stable pitch history
            app.RecentPitchNotes = strings(1,3);

            app.LastConfirmedPitchNote = "";
            app.NoPitchCount = 0;

            app.IsPlaying = true;


            app.ScoreLabel.Text = '0';
            app.ComboLabel.Text = '0';
            % UI PRESENTATION BEGIN
            app.UIEventCount = 0;
            app.UIFeedbackUntil = -Inf;
            app.HitLabel.Text = 'Hit: 0';
            app.MissLabel.Text = 'Miss: 0';
            app.JudgementLabel.Text = 'READY';
            styleRhythmJudgement(app.JudgementLabel);
            % UI PRESENTATION END

            app.CurrentNoteLabel.Text = 'Playing...';
            % UI PRESENTATION BEGIN
            app.UIHasFinalResult = false;
            app.UIFinalSnapshot = [];
            app.UILastValidNote = '---';
            app.UILastValidFrequency = '--- Hz';
            app.PitchCaptionLabel.Text = 'DETECTED NOTE';
            app.ScoreLabel.Tooltip = 'Live score for this round';
            [~,songName,songExtension] = fileparts(app.BeatmapPath);
            app.SongLabel.Text = char(songName + songExtension);
            app.StatusLabel.Text = 'Playing';
            app.StatusLabel.FontColor = [0.568627450980392 0.643137254901961 0.72156862745098];
            app.DetectedNoteLabel.Text = '---';
            app.FrequencyLabel.Text = '--- Hz';
            app.JudgementLabel.Text = 'LISTENING';
            % UI PRESENTATION END


            % Create animation timer
            app.GameTimer = timer( ...
                'ExecutionMode','fixedSpacing', ...
                'Period',0.05, ...
                'TimerFcn',@(~,~)updateGame(app));

            % Draw initial frame
            updateGame(app);

            % Start animation timer
            start(app.GameTimer);



        end

        % Button pushed function: StopButton
        function StopButtonPushed(app, event)

            app.IsPlaying = false;


            if ~isempty(app.GameTimer) && ...
                    isvalid(app.GameTimer)

                stop(app.GameTimer);
                delete(app.GameTimer);
            end

            app.GameTimer = [];

            % Also publish when the player stops before the song ends.
            app.TransportDiagnostics = rhythmTransportDiagnostics( ...
                "finish", app.TransportDiagnostics, numel(app.RawBytes), ...
                true, app.BlocksReceived * app.BlockSize);
                app.TransportStats = finishRhythmTransport(app.TransportStats, ...
                    app.AudioProtocol,app.Fs,numel(app.RawBytes));

            if ~isempty(app.GameClock)
                app.ScoreState = rhythmScore("finish",app.ScoreState,toc(app.GameClock));
                syncScore(app);
            end

            app.CurrentNoteLabel.Text = 'Stopped';
            % UI PRESENTATION BEGIN
            holdFinalResultsUI(app,'Finished');
            % UI PRESENTATION END


            % Disconnect ESP32
            if ~isempty(app.SerialObj)
                if isvalid(app.SerialObj)
                    delete(app.SerialObj);
                end
            end

            app.SerialObj = [];

            % YIN DIAGNOSTIC BEGIN
            if ~isempty(app.PitchRecorder)
                try
                    app.PitchRecorder.finish(app.TransportDiagnostics.Report, ...
                        app.BlocksReceived * app.BlockSize,"stop_button");
                catch diagnosticError
                    warning('YIN diagnostic save failed: %s',diagnosticError.message);
                end
            end
            % YIN DIAGNOSTIC END

            exportFinalScoreEvidence(app,"stop_button");

            fprintf('Total received blocks: %d\n', ...
                app.BlocksReceived);

        end
    end

    % App creation
    methods (Access = public)

        % Construct app
        function app = AudioRhythmGame(varargin)
            app = app@matlab.apps.App(varargin{:});

            if nargout == 0
                clear app
            end
        end
    end
end
