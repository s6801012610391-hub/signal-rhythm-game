function [packets,buffer,stats] = decodeRhythmPackets(buffer,protocol)
% Streaming parser: supports split/burst packets; preserves an incomplete tail.
% Explicit session protocol prevents silently changing Fs during gameplay.
% FaultsBefore=[discarded bytes, invalid packet candidates, receive errors].
    protocol = lower(string(protocol));
    assert(isscalar(protocol) && any(protocol==["legacy","task3"]));
    buffer = uint8(buffer(:));
    stats = struct('AcceptedPackets',0,'ResyncBytes',0,'CRCFailures',0, ...
        'BadHeaders',0,'InvalidSamples',0);
    packets = struct('Packet',{},'ADC',{},'Meta',{},'FaultsBefore',{});
    faults = zeros(1,3);
    if protocol=="legacy"
        magic=uint8([165;90;195;60]); packetBytes=2060;
    else
        magic=uint8('T3AC').'; packetBytes=2068;
    end
    while numel(buffer)>=4
        positions = strfind(char(buffer.'),char(magic.'));
        if isempty(positions)
            discarded = numel(buffer)-3;
            buffer = buffer(end-2:end);
            faults(1)=faults(1)+discarded;
            stats.ResyncBytes=stats.ResyncBytes+discarded;
            break;
        end
        discarded=positions(1)-1;
        buffer(1:discarded)=[];
        faults(1)=faults(1)+discarded;
        stats.ResyncBytes=stats.ResyncBytes+discarded;
        if protocol=="task3"
            if numel(buffer)<16, break; end
            le=@(b) sum(double(b(:)).*256.^(0:numel(b)-1).');
            if le(buffer(5:8))~=16000 || le(buffer(9:10))~=1024 || le(buffer(11:12))~=1
                stats.BadHeaders=stats.BadHeaders+1;
                faults(2)=faults(2)+1;
                buffer(1)=[];
                faults(1)=faults(1)+1;
                stats.ResyncBytes=stats.ResyncBytes+1;
                continue;
            end
        end
        if numel(buffer)<packetBytes, break; end
        packet=buffer(1:packetBytes);
        if protocol=="task3" && ...
                rhythmCRC32(packet(1:2064))~=uint32(le(packet(2065:2068)))
            stats.CRCFailures=stats.CRCFailures+1;
            faults(2)=faults(2)+1;
            buffer(1)=[];
            faults(1)=faults(1)+1;
            stats.ResyncBytes=stats.ResyncBytes+1;
            continue;
        end
        meta=rhythmPacketMetadata(packet);
        payload=packet(meta.PayloadFirst:meta.PayloadLast);
        adc=double(payload(1:2:end))+256*double(payload(2:2:end));
        if any(adc>4095)
            stats.InvalidSamples=stats.InvalidSamples+1;
            faults(2)=faults(2)+1;
            buffer(1)=[];
            % Preserve the old legacy resync counter convention: the first
            % byte of a range-invalid packet counts as invalid, not resync.
            if protocol=="task3"
                faults(1)=faults(1)+1;
                stats.ResyncBytes=stats.ResyncBytes+1;
            end
            continue;
        end
        packets(end+1)=struct('Packet',packet,'ADC',adc,'Meta',meta, ...
            'FaultsBefore',faults); %#ok<AGROW>
        stats.AcceptedPackets=stats.AcceptedPackets+1;
        faults(:)=0;
        buffer(1:packetBytes)=[];
    end
    stats.PendingFaults=faults;
end
