function stats = finishRhythmTransport(stats,protocol,fs,tailBytes)
% Publish once per session. CRC covers ESP32->MATLAB, not FPGA->ESP32 SPI.
    if isempty(stats) || stats.Reported, return; end
    stats.Reported=true;
    report=stats;
    report.Protocol=string(protocol); report.Fs=fs; report.RawBytesRemaining=tailBytes;
    report.MissedTicksAvailable=string(protocol)=="legacy";
    report.CRCChecked=string(protocol)=="task3";
    report.SPIIntegrityVerified=false;
    assignin('base','AudioTransportLog',report);
    fprintf('AUDIO TRANSPORT | %s | Fs %d | packets %d | CRC errors %d | resync bytes %d\n', ...
        protocol,fs,stats.AcceptedPackets,stats.CRCFailures,stats.ResyncBytes);
end
