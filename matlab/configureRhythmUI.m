function configureRhythmUI(app)
% Static UI captions only; reuse the existing figure and dynamic components.
background=rgb('080D17');secondary=rgb('91A4B8');
tags={'SongCaption','ScoreCaption','ComboCaption','FrequencyCaption'};
texts={'SONG','SCORE','COMBO','FREQUENCY'};
positions={[838 640 310 22],[838 555 310 22],[838 465 310 22],[982 204 166 22]};
for k=1:numel(tags)
    tag=['RhythmUI_' tags{k}];label=findall(app.UIFigure,'Tag',tag);
    if isempty(label)
        label=uilabel(app.UIFigure,'Tag',tag);
    end
    label.Text=texts{k};label.Position=positions{k};
    label.BackgroundColor=background;label.FontColor=secondary;
    label.FontName='Bahnschrift';label.FontWeight='bold';label.FontSize=11;
end
styleRhythmJudgement(app.JudgementLabel);
end
function value=rgb(hex)
value=sscanf(hex,'%2x%2x%2x',[1 3])/255;
end
