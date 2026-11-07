function row = pitchDecisionDiagnostic(note,f0,confidence,stable,history, ...
    beatmapMatch,matchedRow,onset,lastConfirmedOnset,dt,pitchLock)
% Describe every existing judgment predicate without changing any app state.
    row.NoteReturned = string(note);
    row.F0Returned = f0;
    row.ConfidenceReturned = confidence;
    row.PitchStable = stable;
    row.StabilityMatchesLast3 = sum(history == string(note));
    row.PitchHistory = strjoin(history,",");
    row.StabilityReason = "STABLE_2_OF_LAST3";
    if ~isfinite(f0) || string(note) == "---"
        row.StabilityReason = "NO_VALID_PITCH";
    elseif row.StabilityMatchesLast3 < 2
        row.StabilityReason = "FEWER_THAN_2_MATCHES_IN_LAST3";
    end
    row.BeatmapMatch = beatmapMatch;
    row.MatchedBeatmapRow = NaN;
    if ~isempty(matchedRow), row.MatchedBeatmapRow = matchedRow; end
    row.OnsetAudio_s = onset;
    row.LastConfirmedOnsetBefore_s = lastConfirmedOnset;
    row.OnsetAgeAudio_s = dt;
    row.PitchLockAtJudgment = string(pitchLock);
    row.ConfidencePass = confidence >= 0.55;
    row.DifferentPitchFromLock = string(note) ~= string(pitchLock);
    row.FiniteOnset = isfinite(onset);
    row.FreshOnset = onset > lastConfirmedOnset;
    row.OnsetTimingPass = dt >= 0.10 && dt <= 0.75;
    reasons = strings(0,1);
    if ~stable, reasons(end+1) = "UNSTABLE_PITCH"; end
    if ~row.ConfidencePass, reasons(end+1) = "CONFIDENCE_BELOW_0_55"; end
    if ~beatmapMatch, reasons(end+1) = "NO_UNJUDGED_NOTE_MATCH_WITHIN_0_35S"; end
    if ~row.DifferentPitchFromLock, reasons(end+1) = "SAME_PITCH_LOCK"; end
    if ~row.FiniteOnset
        reasons(end+1) = "NO_ONSET";
    elseif ~row.FreshOnset
        reasons(end+1) = "ONSET_ALREADY_CONFIRMED";
    end
    if ~isfinite(dt)
        reasons(end+1) = "ONSET_AGE_NOT_FINITE";
    elseif dt < 0.10
        reasons(end+1) = "ONSET_TOO_YOUNG";
    elseif dt > 0.75
        reasons(end+1) = "ONSET_TOO_OLD";
    end
    row.AllJudgmentPredicatesPass = stable && row.ConfidencePass && beatmapMatch && ...
        row.DifferentPitchFromLock && row.FiniteOnset && row.FreshOnset && row.OnsetTimingPass;
    row.JudgmentReasons = strjoin(reasons,";");
    if isempty(reasons), row.JudgmentReasons = "ALL_PREDICATES_PASS"; end
end
