function meta = rhythmPacketMetadata(packet,expectedFs)
% Interpret native headers. T3AC has NO missed-ticks counter; report NaN.
% Integrity is checked by decodeRhythmPackets before delivery to diagnostics.
    validateattributes(packet,{'uint8'},{'vector'});
    packet = packet(:);
    le = @(b) sum(double(b(:)).*256.^(0:numel(b)-1).');
    if numel(packet)==2060 && isequal(packet(1:4),uint8([165;90;195;60]))
        meta = struct('Protocol',"legacy",'Fs',10000,'Sequence',le(packet(5:8)), ...
            'MissedTicks',le(packet(9:12)),'MissedTicksAvailable',true, ...
            'PayloadFirst',13,'PayloadLast',2060,'Format',1);
    elseif numel(packet)==2068 && isequal(packet(1:4),uint8('T3AC').')
        assert(le(packet(5:8))==16000 && le(packet(9:10))==1024 && ...
            le(packet(11:12))==1,'RhythmAudio:Header', ...
            'Task 3 requires Fs=16000, N=1024, unsigned12 format=1.');
        meta = struct('Protocol',"task3",'Fs',16000,'Sequence',le(packet(13:16)), ...
            'MissedTicks',NaN,'MissedTicksAvailable',false, ...
            'PayloadFirst',17,'PayloadLast',2064,'Format',1);
    else
        error('RhythmAudio:Header','Unsupported audio packet.');
    end
    if nargin>1
        assert(meta.Fs==expectedFs,'RhythmAudio:SampleRate', ...
            'Packet Fs differs from the session Fs; restart in the correct mode.');
    end
end
