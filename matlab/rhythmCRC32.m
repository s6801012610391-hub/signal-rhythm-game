function crc = rhythmCRC32(bytes)
% CRC-32/ISO-HDLC, covering the supplied bytes (no implicit CRC trailer).
    persistent lookup
    if isempty(lookup)
        lookup = zeros(256,1,'uint32');
        poly = uint32(hex2dec('EDB88320'));
        for k = 0:255
            c = uint32(k);
            for bit = 1:8
                if bitand(c,uint32(1))
                    c = bitxor(bitshift(c,-1),poly);
                else
                    c = bitshift(c,-1);
                end
            end
            lookup(k+1) = c;
        end
    end
    crc = uint32(hex2dec('FFFFFFFF'));
    for b = reshape(uint8(bytes),1,[])
        index = double(bitand(bitxor(crc,uint32(b)),uint32(255)))+1;
        crc = bitxor(bitshift(crc,-8),lookup(index));
    end
    crc = bitxor(crc,uint32(hex2dec('FFFFFFFF')));
end
