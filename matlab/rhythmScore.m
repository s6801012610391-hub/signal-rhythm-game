function s = rhythmScore(action,s,varargin)
% Score bookkeeping only. Does not detect pitch/onsets or change pitch lock.
% MISS closes after the existing onset matching/confirmation allowance:
% target + .35 s matching window + .75 s confirmation age = target + 1.10 s.
% A gap is not a wrong note. Inadequately observed rows close as UNOBSERVED.
    switch string(action)
        case "init"
            T=validateRhythmBeatmap(varargin{1});fs=varargin{2};
            s=struct('Beatmap',T,'Fs',fs,'Score',0,'Combo',0, ...
                'Outcome',repmat("OPEN",height(T),1),'HandledOnsets',zeros(0,1), ...
                'Grade',repmat("",height(T),1),'TimingError_s',NaN(height(T),1), ...
                'PointsAdded',zeros(height(T),1), ...
                'CoverageStart',Inf,'CoverageEnd',-Inf,'LastPacketGame',NaN, ...
                'Samples',0,'BadThroughSample',0,'Reported',false, ...
                'Events',struct('Game_s',{},'Kind',{},'Row',{},'OnsetSample',{}, ...
                    'Score',{},'Combo',{},'Reason',{}, ...
                    'Grade',{},'TimingError_s',{},'PointsAdded',{}));
        case "audio"
            total=varargin{1};now=varargin{2};broken=varargin{3};
            count=total-s.Samples;assert(count>0);
            delayed=isfinite(s.LastPacketGame) && now-s.LastPacketGame>1;
            if broken || delayed
                s.CoverageStart=Inf;
                s.BadThroughSample=total;
            elseif ~isfinite(s.CoverageStart)
                s.CoverageStart=now-count/s.Fs;
            end
            if ~broken && ~delayed,s.CoverageEnd=now;end
            s.LastPacketGame=now;s.Samples=total;
        case "fault"
            s.CoverageStart=Inf;s.BadThroughSample=s.Samples;
        case "hit"
            row=varargin{1};e=varargin{2};
            if isempty(row) || ~isscalar(row) || row<1 || row>height(s.Beatmap) || ...
                    s.Outcome(row)~="OPEN",return;end
            if ~trusted(s,e) || ~e.FreshOnset || ~e.DifferentPitchFromLock,return;end
            key=round(e.OnsetAudio_s*s.Fs);
            if any(s.HandledOnsets==key),return;end
            if e.Note~=s.Beatmap.Note(row) || ...
                    round(69+12*log2(e.F0/440))~=s.Beatmap.MIDI(row) || ...
                    abs(s.Beatmap.StartTime_s(row)-e.OnsetGame_s)>.35,return;end
            s.HandledOnsets(end+1,1)=key;
            err=e.OnsetGame_s-s.Beatmap.StartTime_s(row);
            % Account only for roundoff from subtracting two timestamps.
            tol=4*eps(max([1,abs(e.OnsetGame_s),abs(s.Beatmap.StartTime_s(row))]));
            if abs(err)<=.10+tol
                grade="PERFECT";points=100;
            elseif abs(err)<=.20+tol
                grade="GREAT";points=75;
            else
                grade="GOOD";points=50;
            end
            s.Grade(row)=grade;s.TimingError_s(row)=err;s.PointsAdded(row)=points;
            s.Outcome(row)="HIT";s.Score=s.Score+points;s.Combo=s.Combo+1;
            s=event(s,e.Game_s,"HIT",row,key,"CONFIRMED_TARGET");
        case "wrong"
            e=varargin{1};
            if ~trusted(s,e) || ~e.FreshOnset || ~e.DifferentPitchFromLock,return;end
            key=round(e.OnsetAudio_s*s.Fs);
            if any(s.HandledOnsets==key),return;end
            eligible=s.Outcome=="OPEN" & abs(s.Beatmap.StartTime_s-e.OnsetGame_s)<=.35;
            % If any eligible target matches, this is not a proven wrong note.
            if ~any(eligible) || any(eligible & s.Beatmap.Note==e.Note),return;end
            rows=find(eligible);[~,j]=min(abs(s.Beatmap.StartTime_s(rows)-e.OnsetGame_s));row=rows(j);
            s.HandledOnsets(end+1,1)=key;
            s.Outcome(row)="WRONG";s.Combo=0;
            s.Grade(row)="WRONG";s.TimingError_s(row)=e.OnsetGame_s-s.Beatmap.StartTime_s(row);
            s=event(s,e.Game_s,"WRONG",row,key,"STABLE_WRONG_PITCH_WITH_NEW_ONSET");
        case "advance"
            now=varargin{1};
            rows=find(s.Outcome=="OPEN" & now>s.Beatmap.StartTime_s+1.10);
            for row=rows(:).'
                deadline=s.Beatmap.StartTime_s(row)+1.10;
                if s.CoverageEnd<deadline,continue;end
                if s.CoverageStart<=max(0,s.Beatmap.StartTime_s(row)-.35)
                    s.Outcome(row)="MISS";s.Combo=0;
                    s.Grade(row)="MISS";
                    s=event(s,now,"MISS",row,NaN,"NO_CONFIRMED_HIT_WITH_CONTINUOUS_AUDIO");
                else
                    s.Outcome(row)="UNOBSERVED";
                    s.Grade(row)="UNOBSERVED";
                    s=event(s,now,"UNOBSERVED",row,NaN,"INCOMPLETE_AUDIO_COVERAGE");
                end
            end
        case "finish"
            if isempty(s) || s.Reported,return;end
            now=varargin{1};s=rhythmScore("advance",s,now);
            rows=find(s.Outcome=="OPEN" & now>s.Beatmap.StartTime_s+1.10);
            for row=rows(:).'
                s.Outcome(row)="UNOBSERVED";
                s.Grade(row)="UNOBSERVED";
                s=event(s,now,"UNOBSERVED",row,NaN,"NO_COMPLETE_AUDIO_COVERAGE_AT_STOP");
            end
            s.Reported=true;
            ScoreLog=s; %#ok<NASGU>
            assignin('base','ScoreLog',ScoreLog);
            fprintf('SCORE SUMMARY | Score %d | Combo %d | Hit %d | Wrong %d | Miss %d | Unobserved %d\n', ...
                s.Score,s.Combo,sum(s.Outcome=="HIT"),sum(s.Outcome=="WRONG"), ...
                sum(s.Outcome=="MISS"),sum(s.Outcome=="UNOBSERVED"));
        otherwise
            error('RhythmScore:Action','Unknown action.');
    end
end
function ok=trusted(s,e)
    ok=e.Stable && isfinite(e.F0) && e.F0>0 && e.Confidence>=.55 && ...
        isfinite(e.OnsetAudio_s) && isfinite(e.OnsetGame_s) && ...
        isfinite(e.Age_s) && e.Age_s>=.10 && e.Age_s<=.75 && ...
        e.Note~="---" && e.AudioSampleFirst>=1 && ...
        e.AudioSampleFirst+2047<=s.Samples && ...
        round(e.OnsetAudio_s*s.Fs)>s.BadThroughSample && ...
        e.OnsetAudio_s<=s.Samples/s.Fs && ...
        e.AudioSampleFirst>s.BadThroughSample && e.ContinuityValid;
end
function s=event(s,time,kind,row,key,reason)
    s.Events(end+1)=struct('Game_s',time,'Kind',kind,'Row',row, ...
        'OnsetSample',key,'Score',s.Score,'Combo',s.Combo,'Reason',reason, ...
        'Grade',s.Grade(row),'TimingError_s',s.TimingError_s(row), ...
        'PointsAdded',s.PointsAdded(row));
end
