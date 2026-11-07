function result=exportRhythmScore(state,meta,folder)
% Persistence only: copies scorer fields; never detects, judges or mutates state.
root=fileparts(mfilename('fullpath'));
if nargin<3,folder=fullfile(root,'scorelogs');end
result=struct('Success',false,'AlreadyExists',false,'File',"",'SessionID',"",'Error',"");
try
    canonical=strrep(char(folder),'/',filesep);
    parts=strsplit(canonical,filesep);
    assert(~any(strcmp(parts,'..')) && ~any(strcmp(parts,'.')), ...
        'RhythmGame:ExportFolder','Relative path components are not accepted.');
    allowed=[root filesep];
    assert(startsWith(lower([canonical filesep]),lower(allowed)), ...
        'RhythmGame:ExportFolder','Score logs must remain inside the MATLAB source folder.');
    assert(isstruct(state) && isfield(state,'Beatmap') && istable(state.Beatmap));
    assert(isfield(state,'Reported') && state.Reported,'Only a finished scorer state can be exported.');
    session=string(meta.SessionID);assert(isscalar(session) && ~isempty(regexp(char(session),'^[A-Za-z0-9_-]+$','once')));
    result.SessionID=session;
    file=fullfile(canonical,char("ScoreLog_"+session+".csv"));result.File=string(file);
    if isfile(file),result.Success=true;result.AlreadyExists=true;return;end
    if ~isfolder(canonical),mkdir(canonical);end
    n=height(state.Beatmap);T=table;
    T.SessionID=repmat(session,n,1);
    T.SessionStartBangkok=repmat(metaValue(meta,'SessionStartBangkok'),n,1);
    T.ExportTimeBangkok=repmat(string(datetime('now','TimeZone','Asia/Bangkok','Format','yyyy-MM-dd HH:mm:ss.SSS Z')),n,1);
    T.Beatmap=repmat(metaValue(meta,'Beatmap'),n,1);
    T.DiagnosticFile=repmat(metaValue(meta,'DiagnosticFile'),n,1);
    T.RuntimeFile=repmat(metaValue(meta,'RuntimeFile'),n,1);
    T.EndReason=repmat(metaValue(meta,'EndReason'),n,1);
    T.NoteRow=(1:n)';T.TargetNote=string(state.Beatmap.Note);T.TargetMIDI=state.Beatmap.MIDI;
    T.TargetTime_s=state.Beatmap.StartTime_s;T.Duration_s=state.Beatmap.Duration_s;
    unavailable=strings(0,1);
    [T.Outcome,missing]=stateValue(state,'Outcome',n,true);if missing,unavailable(end+1)="Outcome";end
    [T.Grade,missing]=stateValue(state,'Grade',n,true);if missing,unavailable(end+1)="Grade";end
    [T.ScoreAwarded,missing]=stateValue(state,'PointsAdded',n,false);if missing,unavailable(end+1)="PointsAdded";end
    [T.TimingError_s,missing]=stateValue(state,'TimingError_s',n,false);if missing,unavailable(end+1)="TimingError_s";end
    [score,missing]=stateValue(state,'Score',1,false);if missing,unavailable(end+1)="Score";end
    [combo,missing]=stateValue(state,'Combo',1,false);if missing,unavailable(end+1)="Combo";end
    T.FinalScore=repmat(score,n,1);T.FinalCombo=repmat(combo,n,1);
    % Counts are direct aggregates of actual scorer outcomes, as used by the HUD.
    for kind=["HIT","MISS","WRONG","UNOBSERVED","OPEN"]
        value=NaN;if isfield(state,'Outcome'),value=sum(state.Outcome==kind);end
        T.("Final"+kind)=repmat(value,n,1);
    end
    T.UnavailableFields=repmat(strjoin(unavailable,';'),n,1);
    tmp=[tempname(canonical) '.csv'];cleanup=onCleanup(@() removePartial(tmp)); %#ok<NASGU>
    writetable(T,tmp,'Encoding','UTF-8');
    assert(~isfile(file),'A session export already exists; refusing overwrite.');
    [ok,message]=movefile(tmp,file);assert(ok,'%s',message);
    result.Success=true;
catch ME
    result.Error=string(ME.identifier)+": "+string(ME.message);
end
end
function value=metaValue(meta,key)
value="NOT AVAILABLE";if isfield(meta,key),value=string(meta.(key));end
end
function [value,missing]=stateValue(state,key,n,text)
missing=~isfield(state,key);
if missing
    if text,value=repmat("NOT AVAILABLE",n,1);else,value=NaN(n,1);end
else
    value=state.(key);if text,value=string(value);end
    value=value(:);assert(numel(value)==n,'Unexpected scorer field size: %s',key);
end
end
function removePartial(file)
if isfile(file),delete(file);end
end
