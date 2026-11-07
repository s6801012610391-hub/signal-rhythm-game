function app = runRhythmGame(mode, port)
% Launch the MATLAB rhythm game from its source and UI layout.
% The runtime class is generated locally to keep one canonical app source.
    if nargin < 1, mode = "task3"; end
    if nargin < 2, port = "COM3"; end
    mode = lower(string(mode));
    assert(isscalar(mode) && any(mode == ["legacy", "task3"]), ...
        'RhythmGame:Mode', 'Unsupported audio mode.');

    here = fileparts(mfilename('fullpath'));
    addpath(here, '-begin');
    cd(here); % Relative XML location is used by the MATLAB app.
    xmlFile = fullfile(here, 'AudioRhythmGame.xml');
    assert(isfile(xmlFile), 'RhythmGame:XML', 'Missing AudioRhythmGame.xml.');

    source = fileread(fullfile(here, 'AudioRhythmGame.m'));
    runtime = strrep(source, ...
        'classdef AudioRhythmGame < matlab.apps.App', ...
        'classdef RhythmGameRuntime < matlab.apps.App');
    runtime = strrep(runtime, ...
        'function app = AudioRhythmGame(varargin)', ...
        'function app = RhythmGameRuntime(varargin)');
    assert(~strcmp(runtime, source), 'RhythmGame:Source', ...
        'Could not derive the runtime class from the source.');

    runtimeFile = fullfile(here, 'RhythmGameRuntime.m');
    if ~isfile(runtimeFile) || ~strcmp(fileread(runtimeFile), runtime)
        fid = fopen(runtimeFile, 'w', 'n', 'UTF-8');
        assert(fid >= 0, 'RhythmGame:Write', ...
            'Cannot write the generated runtime class.');
        closer = onCleanup(@() fclose(fid));
        fprintf(fid, '%s', runtime);
        clear closer;
        clear RhythmGameRuntime;
        rehash;
    end
    assert(strcmpi(which('RhythmGameRuntime'), runtimeFile), ...
        'RhythmGame:Path', 'A different runtime class is on the MATLAB path.');

    assignin('base', 'RhythmAudioMode', mode);
    assignin('base', 'RhythmCOMPort', string(port));
    app = RhythmGameRuntime();
end
