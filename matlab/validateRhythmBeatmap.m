function T = validateRhythmBeatmap(T)
% Transactional CSV validation: caller installs the beatmap only on success.
    required={'Note','MIDI','StartTime_s','Duration_s'};
    assert(istable(T) && all(ismember(required,T.Properties.VariableNames)), ...
        'RhythmCSV:Columns','CSV requires Note, MIDI, StartTime_s and Duration_s.');
    assert(height(T)>0,'RhythmCSV:Empty','Beatmap is empty.');
    for key={'MIDI','StartTime_s','Duration_s'}
        x=T.(key{1});
        assert(isnumeric(x) && isreal(x) && iscolumn(x) && all(isfinite(x)), ...
            'RhythmCSV:Numeric','%s must contain finite real numeric values.',key{1});
    end
    assert(all(T.StartTime_s>=0) && all(T.Duration_s>0) && ...
        all(isfinite(T.StartTime_s+T.Duration_s)) && all(T.MIDI==round(T.MIDI)), ...
        'RhythmCSV:Values','Invalid MIDI or timing values.');
    assert(isstring(T.Note) || iscellstr(T.Note) || iscategorical(T.Note), ...
        'RhythmCSV:Note','Note must contain text note names.');
    note=string(T.Note);
    assert(iscolumn(note) && ~any(ismissing(note)) && all(strlength(note)>0), ...
        'RhythmCSV:Note','Note names must not be missing or empty.');
    names=["C4","D4","E4","F4","G4","A4","B4"];
    midi=[60 62 64 65 67 69 71];
    [known,index]=ismember(note,names);
    assert(all(known),'RhythmCSV:Note','Only C4 D4 E4 F4 G4 A4 B4 are supported.');
    expected=reshape(midi(index),[],1);
    bad=find(T.MIDI~=expected,1);
    if ~isempty(bad)
        error('RhythmCSV:Mismatch','Row %d: %s requires MIDI %d; found %g.', ...
            bad,note(bad),expected(bad),T.MIDI(bad));
    end
    T.Note=note;
    T=sortrows(T,'StartTime_s');
end
