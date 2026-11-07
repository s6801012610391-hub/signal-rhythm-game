function config = rhythmAudioConfig()
% Legacy remains the default. runRhythmGame selects the session explicitly.
    mode="legacy"; port="COM3";
    if evalin('base','exist(''RhythmAudioMode'',''var'') == 1')
        mode=lower(string(evalin('base','RhythmAudioMode')));
    end
    if evalin('base','exist(''RhythmCOMPort'',''var'') == 1')
        port=string(evalin('base','RhythmCOMPort'));
    end
    assert(isscalar(mode) && any(mode==["legacy","task3"]), ...
        'RhythmAudio:Mode','Mode must be legacy or task3.');
    assert(isscalar(port) && strlength(port)>0,'RhythmAudio:Port','Specify one COM port.');
    config=struct('Protocol',mode,'Port',port,'Fs',10000,'PacketSize',2060);
    if mode=="task3", config.Fs=16000; config.PacketSize=2068; end
end
