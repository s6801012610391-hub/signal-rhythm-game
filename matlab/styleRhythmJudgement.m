function styleRhythmJudgement(label)
% Presentation only: read the existing label; never judge or change its text.
switch upper(string(label.Text))
    case "PERFECT"
        foreground='0FD4EB';background='0E3847';
    case "GREAT"
        foreground='21E8AD';background='11362B';
    case "GOOD"
        foreground='FFC457';background='3B2E1A';
    case "MISS"
        foreground='FF759B';background='3B1B26';
    case {"WRONG","WRONG NOTE"}
        foreground='FFC457';background='3B2E1A';
    case {"UNOBSERVED","CHECK AUDIO"}
        foreground='91A4B8';background='101B2A';
    otherwise % READY / LISTENING / OPEN and other existing text
        foreground='16D9EB';background='101B2A';
end
label.FontColor=rgb(foreground);label.BackgroundColor=rgb(background);
end
function value=rgb(hex)
value=sscanf(hex,'%2x%2x%2x',[1 3])/255;
end
