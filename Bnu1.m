classdef Bnu1 < matlab.apps.AppBase
    % Properties that correspond to app components
    properties (Access = public)
        BnuUIFigure          matlab.ui.Figure
        EventsTextArea       matlab.ui.control.TextArea
        EventsTextAreaLabel  matlab.ui.control.Label
        T2          matlab.ui.control.NumericEditField
        Label_6              matlab.ui.control.Label
        T1          matlab.ui.control.NumericEditField
        Label_5              matlab.ui.control.Label
        C          matlab.ui.control.NumericEditField
        Label_4              matlab.ui.control.Label
        i            matlab.ui.control.NumericEditField
        Label_i              matlab.ui.control.Label
        Label                matlab.ui.control.Label
        StopButton           matlab.ui.control.Button
        StartTherapyButton   matlab.ui.control.Button
        ConnectButton        matlab.ui.control.Button
        UIAxes               matlab.ui.control.UIAxes
    end
    properties (Access = private)
        ipos = 0;           % Time index for plotting
        signalBuffer = [];  % Buffer for signal values
        isConnected = false % Connection flag
        therapyStarted = false;       % Flag to begin A2-A1 analysis
        pdev                % Pulse.CoDevice object
        dataTimer           % MATLAB timer object
        A0_detected = false;       % Flag to ensure message shown only once
        A2A1_differences = [];     % Stores A2 - A1 differences
        peaksTable = table();      % Table to store A1, A2, and their timestamps
        groupedMeansTable = table();   % Table for grouped averages
        groupedMeans = [];
        groupCount = 0;
        espIpAddress string = "http://192.168.43.112";
        therapyTimer;  % Timer for therapy duration
        therapyRunning  logical = false; % Whether therapy is currently running
        % --- New Constants and Properties ---
        SAMPLING_FREQUENCY = 100; % Hz
        MAX_BUFFER_LENGTH = 1000; % Number of samples for ~10 seconds of data at 100 Hz
        MIN_PEAK_DISTANCE_SAMPLES = 80; % Desired minimum peak distance (0.8 seconds)
        MIN_PEAK_PROMINENCE = 800; % Increased: Changed from 500 to 800 for stricter peak detection
        MIN_A2_AMPLITUDE = 500; % New: Minimum acceptable A2 amplitude
        MAD_K_FACTOR = 4; % Tunable factor for MAD outlier removal (No longer used directly but kept for context)
        GROUP_SIZE = 300; % Number of A2-A1 differences per group
        MIN_GROUPS_FOR_C_CHECK = 6; % Minimum number of groups before checking C threshold
        PEAK_TEXT_OFFSET = 50; % Offset for A1/A2 text labels on plot
        lastA2Detected = NaN; % Stores the last A2 value successfully processed
    end
    % Callbacks that handle component events
    methods (Access = private)
        function response = SendEspRequest(app, endpoint)
            url = app.espIpAddress + endpoint;
            try
                response = webread(url);
            catch ME
                app.EventsTextArea.Value = [app.EventsTextArea.Value;
                    "ESP Error: " + ME.message];
                response = '';
            end
        end
        % Button pushed function: ConnectButton
        function ConnectButtonPushed(app, event)
            try
                if ~app.isConnected
                    % Create COM object only if not already created
                    if isempty(app.pdev)
                        app.pdev = actxserver('Pulse.CoDevice');
                    end
                    result = app.pdev.Connect();
                    % Important: Connect() returns 0 on failure, non-zero on success
                    if result == 0
                        app.EventsTextArea.Value = ["Connection failed: Device not responding. Please check hardware connection."];
                        return;
                    end
                    % Connection succeeded
                    app.isConnected = true;
                    app.EventsTextArea.Value = ["Connected to device. Press 'Start Therapy' to begin data acquisition."];
                    app.ConnectButton.Text = "Disconnect";
                    app.ConnectButton.BackgroundColor = [0.466 0.674 0.188]; % Green for connected
                    app.StartTherapyButton.Enable = 'on'; % Enable therapy button after connection
                    % Initialize/Reset buffers and flags on connect
                    app.signalBuffer = zeros(app.MAX_BUFFER_LENGTH, 1); % Pre-allocate buffer
                    app.ipos = 0;
                    app.A2A1_differences = [];
                    app.peaksTable = table(); % Clear peaks table
                    app.groupedMeansTable = table();
                    app.groupedMeans = [];
                    app.groupCount = 0;
                    app.A0_detected = false; % Reset A0 detection flag
                    app.therapyStarted = false; % Ensure therapy flag is off
                    app.therapyRunning = false; % Ensure therapy running flag is off
                    app.lastA2Detected = NaN; % Reset last A2 detected
                    % Clear plot
                    cla(app.UIAxes);
                    xlabel(app.UIAxes, 'Time (s)')
                    ylabel(app.UIAxes, 'Amplitude')
                    title(app.UIAxes, 'PPG Signal (Connected - Waiting for Therapy Start)') % Indicate status
                    legend(app.UIAxes, 'off'); % Clear legend
                    grid(app.UIAxes, 'on');
                    % Setup data timer, but do not start it here.
                    % It will be started by StartTherapyButtonPushed.
                    if isempty(app.dataTimer) || ~isvalid(app.dataTimer)
                        app.dataTimer = timer( ...
                            'ExecutionMode', 'fixedRate', ...
                            'Period', 1/app.SAMPLING_FREQUENCY, ... % Adjust period to match sampling frequency
                            'TimerFcn', @(~, ~) fetchAndPlot(app));
                    end
                else
                    % Disconnect logic
                    app.stopTimers(); % Stop both timers
                    if ~isempty(app.pdev)
                        app.pdev.Disconnect();
                    end
                    app.isConnected = false;
                    app.EventsTextArea.Value = ["Disconnected from device."];
                    app.ConnectButton.Text = "Connect";
                    app.ConnectButton.BackgroundColor = [0.8 0.8 0.8]; % Gray for disconnected
                    app.StartTherapyButton.Enable = 'off'; % Disable therapy button
                    app.StopButtonPushed([]); % Call stop to clear everything and reset UI
                end
            catch ME
                app.EventsTextArea.Value = ["Error during connection: " + ME.message];
                app.isConnected = false;
                app.ConnectButton.Text = "Connect";
                app.ConnectButton.BackgroundColor = [0.8 0.8 0.8];
                app.StartTherapyButton.Enable = 'off';
                app.stopTimers(); % Ensure timers are stopped on error
            end
        end
        % Button pushed function: StartTherapyButton
        function StartTherapyButtonPushed(app, event)
            app.EventsTextArea.Value = [app.EventsTextArea.Value; "Start Therapy button pressed. Initializing..."];
            % Ensure device is connected before starting therapy
            if ~app.isConnected
                app.EventsTextArea.Value = [app.EventsTextArea.Value; "Error: Device not connected. Please connect first."];
                return;
            end
            % Reset all therapy-related buffers and flags
            app.therapyStarted = true;
            app.A0_detected = false;
            % Clear old data to start fresh
            app.signalBuffer = zeros(app.MAX_BUFFER_LENGTH, 1); % Re-initialize and pre-allocate
            app.ipos = 0;
            app.A2A1_differences = [];              % Clear A2-A1 differences
            app.peaksTable = table();               % Clear peaks log
            app.groupedMeans = [];                  % Clear grouped averages
            app.groupedMeansTable = table();        % Clear grouped means table
            app.groupCount = 0;
            app.lastA2Detected = NaN; % Reset last A2 detected for new therapy session
            % Ensure previous therapy timer is stopped
            if ~isempty(app.therapyTimer) && isvalid(app.therapyTimer) && strcmp(app.therapyTimer.Running, 'on')
                stop(app.therapyTimer);
                delete(app.therapyTimer);
                app.therapyTimer = [];
            end
            % Get T1 and T2 values in minutes, convert to seconds
            minTimeMinutes = app.T1.Value;
            maxTimeMinutes = app.T2.Value;
            % Validate input values
            if isnan(minTimeMinutes) || isnan(maxTimeMinutes)
                app.EventsTextArea.Value = [app.EventsTextArea.Value;
                    "Error: Please enter valid numbers for T1 (min) and T2 (min)."];
                return;
            end
            minTimeSeconds = minTimeMinutes * 60;
            maxTimeSeconds = maxTimeMinutes * 60;
            if maxTimeSeconds <= minTimeSeconds
                app.EventsTextArea.Value = [app.EventsTextArea.Value;
                    "Error: Maximum therapy duration (T2) must be greater than Minimum therapy duration (T1)."];
                return;
            end
            % Create therapy timer (checks every second)
            app.therapyTimer = timer(...
                'ExecutionMode', 'fixedRate', 'Period', 1, ... % Check every second
                'TimerFcn', @(~,~) checkTherapyDuration(app, minTimeSeconds, maxTimeSeconds));
            start(app.therapyTimer);
            % Set flags
            app.therapyRunning = true;
            app.StartTherapyButton.Enable = 'off'; % Disable Start button during therapy
            app.StopButton.Enable = 'on'; % Enable Stop button
            % --- START DATA TIMER HERE ---
            app.EventsTextArea.Value = [app.EventsTextArea.Value; "Attempting to start data acquisition timer..."];
            try
                if ~isempty(app.dataTimer) && isvalid(app.dataTimer) && strcmp(app.dataTimer.Running, 'off')
                    start(app.dataTimer);
                    app.EventsTextArea.Value = [app.EventsTextArea.Value; "Data timer successfully started."];
                elseif isempty(app.dataTimer)
                    app.EventsTextArea.Value = [app.EventsTextArea.Value; "Error: Data timer object is empty. Please ensure device connection was successful and try again."];
                elseif ~isvalid(app.dataTimer)
                    app.EventsTextArea.Value = [app.EventsTextArea.Value; "Error: Data timer object is invalid. This might require restarting the app."];
                elseif strcmp(app.dataTimer.Running, 'on')
                    app.EventsTextArea.Value = [app.EventsTextArea.Value; "Data timer is already running (unexpected state)."];
                end
            catch ME
                app.EventsTextArea.Value = [app.EventsTextArea.Value; "Critical Error starting data timer: " + ME.message];
                app.stopTherapyProcedure(); % Attempt to stop gracefully on critical error
                return;
            end
            % Log events
            app.EventsTextArea.Value = [app.EventsTextArea.Value;
                sprintf('Therapy timer started. Will stop after %.0f minutes (%.0f seconds).', maxTimeMinutes, maxTimeSeconds)];
            app.EventsTextArea.Value = [app.EventsTextArea.Value;
                "Therapy started. A2-A1 detection initialized..."];
            title(app.UIAxes, 'PPG Signal (Therapy Running)'); % Update plot title
        end
        function checkTherapyDuration(app, minTimeSeconds, maxTimeSeconds)
            persistent startTime;
            if isempty(startTime) || ~app.therapyRunning % Reset startTime if therapy restarts
                startTime = tic;
            end
            elapsedTime = toc(startTime);
            % Show elapsed time in UI
            app.Label.Text = sprintf('Elapsed: %.0f sec', elapsedTime);
            % Warn user when minimum time is reached
            if elapsedTime >= minTimeSeconds && ~app.A0_detected
                % Check if the message has already been displayed
                if isempty(strfind(app.EventsTextArea.Value{end}, 'Minimum therapy time (T1) reached'))
                    app.EventsTextArea.Value = [app.EventsTextArea.Value;
                        'Minimum therapy time (T1) reached. Still waiting for A0 (initial average difference) detection...'];
                end
            end
            % Stop therapy when maximum time is reached
            if elapsedTime >= maxTimeSeconds
                app.EventsTextArea.Value = [app.EventsTextArea.Value;
                    sprintf('Maximum therapy time (T2 = %.0f sec) reached. Therapy stopped.', maxTimeSeconds)];
                app.stopTherapyProcedure();
                startTime = []; % Corrected: clear startTime; to startTime = [];
            end
        end
        function StopButtonPushed(app, event)
            app.EventsTextArea.Value = [app.EventsTextArea.Value;
                "Manual Stop: Therapy stopping and data clearing..."];
            app.stopTherapyProcedure();
        end
        function stopTherapyProcedure(app)
            % Stop therapy timer if active
            if ~isempty(app.therapyTimer) && isvalid(app.therapyTimer) && strcmp(app.therapyTimer.Running, 'on')
                stop(app.therapyTimer);
                delete(app.therapyTimer);
                app.therapyTimer = [];
            end
            % Stop data timer (do not delete, it is reused)
            if ~isempty(app.dataTimer) && isvalid(app.dataTimer) && strcmp(app.dataTimer.Running, 'on')
                stop(app.dataTimer);
            end
            % Save data before clearing
            app.savePeaksTable(); % Call the new save function
            % Reset flags
            app.therapyStarted = false;
            app.therapyRunning = false;
            app.A0_detected = false;
            % Clear buffers and tables
            app.signalBuffer = zeros(app.MAX_BUFFER_LENGTH, 1); % Reset buffer to zeros
            app.ipos = 0;
            app.A2A1_differences = [];
            app.peaksTable = table();      % Clear peaks table AFTER saving
            app.groupedMeansTable = table();  % Clear grouped means table
            app.groupedMeans = [];         % Clear group averages
            app.groupCount = 0;
            app.lastA2Detected = NaN; % Reset last A2 detected
            % Clear plot
            cla(app.UIAxes);
            xlabel(app.UIAxes, 'Time (s)')
            ylabel(app.UIAxes, 'Amplitude')
            title(app.UIAxes, 'PPG Signal (Stopped)') % Indicate status
            legend(app.UIAxes, 'off');
            grid(app.UIAxes, 'on');
            % Optional: Turn off LED via ESP
            try
                app.SendEspRequest("/off");
            catch ME
                app.EventsTextArea.Value = [app.EventsTextArea.Value; ...
                    "Warning: Could not send OFF command to ESP: " + ME.message];
            end
            % Update UI
            app.Label.Text = ''; % Clear elapsed time label
            app.StartTherapyButton.Enable = 'on'; % Re-enable Start button
            app.StopButton.Enable = 'off'; % Disable Stop button
            app.EventsTextArea.Value = [app.EventsTextArea.Value;
                "Therapy stopped and all data cleared."];
        end
        function stopTimers(app)
            % Stop data timer (do not delete, it is reused)
            if ~isempty(app.dataTimer) && isvalid(app.dataTimer) && strcmp(app.dataTimer.Running, 'on')
                stop(app.dataTimer);
            end
            % Stop and delete therapy timer
            if ~isempty(app.therapyTimer) && isvalid(app.therapyTimer) && strcmp(app.therapyTimer.Running, 'on')
                stop(app.therapyTimer);
                delete(app.therapyTimer);
                app.therapyTimer = [];
            end
        end
        % New: Function to save peaksTable automatically
        function savePeaksTable(app)
            if isempty(app.peaksTable)
                app.EventsTextArea.Value = [app.EventsTextArea.Value; "No A2-A1 data to save."];
                return;
            end
            
            % Generate a timestamped filename
            fileName = sprintf('signallog_%s.csv', datestr(now, 'yyyy-mm-dd_HHMMSS'));
            
            try
                writetable(app.peaksTable, fileName);
                app.EventsTextArea.Value = [app.EventsTextArea.Value;
                    sprintf('A2-A1 differences automatically saved to: %s', fileName)];
            catch ME
                app.EventsTextArea.Value = [app.EventsTextArea.Value;
                    sprintf('Error automatically saving data: %s', ME.message)];
            end
        end

        function fetchAndPlot(app)
            try
                % Only proceed if connected and therapy is running
                if isempty(app.pdev) || ~app.isConnected || ~app.therapyRunning
                    if app.therapyRunning % Only log if expected to be running but conditions aren't met
                         app.EventsTextArea.Value = [app.EventsTextArea.Value; "fetchAndPlot: Conditions not met (pdev empty/not connected/therapy not running). Stopping data acquisition."];
                         app.stopTimers(); % Ensure data timer is stopped if conditions are unexpectedly false
                    end
                    return;
                end
                
                % Get raw ADC data from device
                % Wrap GetRawData in try-catch to handle COM object errors
                try
                    rawData = app.pdev.GetRawData();  % Returns SAFEARRAY(long)
                catch ME_COM
                    app.EventsTextArea.Value = [app.EventsTextArea.Value; "fetchAndPlot: Error calling GetRawData: " + ME_COM.message + ". Attempting to stop data acquisition."];
                    app.stopTimers(); % Stop timers if COM object method fails
                    return;
                end
                
                % --- Debugging: Check rawData status ---
                if isempty(rawData)
                    return; % Exit if no data
                elseif all(rawData == 0)
                    return; % Exit if all zeros
                else
                    % Convert rawData to usable numeric form
                    if iscell(rawData)
                        rawData = double(cell2mat(rawData));
                    elseif isstruct(rawData)
                        rawData = double(rawData.Value);
                    else
                        rawData = double(rawData);  % Convert int32 to double
                    end
                    rawData = rawData(:);  % Ensure it's a column vector
                end
                % --- End Debugging ---
                % Append new data to buffer
                currentBufferLength = length(app.signalBuffer);
                newLength = currentBufferLength + length(rawData);
                % Efficiently update buffer (circular buffer-like behavior for plotting window)
                if newLength > app.MAX_BUFFER_LENGTH
                    app.signalBuffer = [app.signalBuffer(newLength - app.MAX_BUFFER_LENGTH + 1 : end); rawData];
                else
                    % If buffer is not yet full, append to the current end
                    if app.ipos + length(rawData) <= app.MAX_BUFFER_LENGTH
                        app.signalBuffer(app.ipos + 1 : app.ipos + length(rawData)) = rawData;
                    else % If appending would exceed MAX_BUFFER_LENGTH, take only the latest part
                        overflow = (app.ipos + length(rawData)) - app.MAX_BUFFER_LENGTH;
                        app.signalBuffer = [app.signalBuffer(overflow + 1 : end); rawData];
                    end
                end
                % Prepare time vector for the current plot window
                t = (0:length(app.signalBuffer)-1) / app.SAMPLING_FREQUENCY;
                % Smooth the signal to reduce noise
                smoothedSignal = movmean(app.signalBuffer, 10);  % Moving average filter
                % Dynamic thresholding for peak detection
                dynamicThreshold = mean(smoothedSignal) + std(smoothedSignal);
                if isnan(dynamicThreshold) || isinf(dynamicThreshold)
                    dynamicThreshold = 0; % Fallback if signal is flat or invalid
                end
                % --- Dynamic MinPeakDistance calculation ---
                % Ensure MinPeakDistance is always at least 1 and less than half the signal length
                % to prevent errors when the buffer is still filling.
                actualMinPeakDistance = max(1, min(app.MIN_PEAK_DISTANCE_SAMPLES, floor(length(smoothedSignal) / 2) - 1));
                
                % If the signal is too short for any meaningful peak detection (e.g., less than 2 samples)
                if length(smoothedSignal) < 2
                     pks_max = []; locs_max = []; pks_min = []; locs_min = []; % Clear peaks
                else
                    % Find maxima (A2)
                    [pks_max, locs_max] = findpeaks(smoothedSignal, ...
                        'MinPeakHeight', dynamicThreshold, ...
                        'MinPeakDistance', actualMinPeakDistance, ...
                        'MinPeakProminence', app.MIN_PEAK_PROMINENCE);
                    % Find minima (A1)
                    [pks_min, locs_min] = findpeaks(-smoothedSignal, ...
                        'MinPeakHeight', -dynamicThreshold, ...
                        'MinPeakDistance', actualMinPeakDistance, ...
                        'MinPeakProminence', app.MIN_PEAK_PROMINENCE);
                    pks_min = -pks_min;  % Restore original minima values
                end
                if app.therapyStarted % Only process A2-A1 differences if therapy is truly started
                    % Skip processing until we have enough signal data for meaningful analysis
                    if length(app.signalBuffer) < app.SAMPLING_FREQUENCY * 2 % At least 2 seconds of data
                    else
                        % Match A1 and A2 peaks more robustly
                        [matchedA1, matchedA2, matchedTimes, diffs] = app.matchPeaks(t, smoothedSignal, pks_min, locs_min, pks_max, locs_max);
                        
                        % --- New Anomaly Fix: Check if new A2 is identical to the previous one and if it meets MIN_A2_AMPLITUDE ---
                        validMatchedA1 = [];
                        validMatchedA2 = [];
                        validMatchedTimes = [];
                        validDiffs = [];

                        for k = 1:length(matchedA2)
                            currentA2 = matchedA2(k);
                            % Check 1: Current A2 must be different from the last successfully detected A2
                            % Using a small tolerance for floating point comparison
                            % Check 2: Current A2 must be greater than MIN_A2_AMPLITUDE
                            if (abs(currentA2 - app.lastA2Detected) > 0.001 || isnan(app.lastA2Detected)) && (currentA2 > app.MIN_A2_AMPLITUDE)
                                validMatchedA1 = [validMatchedA1; matchedA1(k)];
                                validMatchedA2 = [validMatchedA2; currentA2];
                                validMatchedTimes = [validMatchedTimes; matchedTimes(k)];
                                validDiffs = [validDiffs; diffs(k)];
                                app.lastA2Detected = currentA2; % Update last A2 detected
                            end
                        end

                        if ~isempty(validDiffs)
                            % Append to full diff list
                            app.A2A1_differences = [app.A2A1_differences; validDiffs];

                            % Log peaks in table (only if they correspond to processed diffs)
                            if ~isempty(validMatchedTimes)
                                newRows = table(validMatchedTimes, validMatchedA1, validMatchedA2, validDiffs, ...
                                    'VariableNames', {'Time', 'A1', 'A2', 'A2_minus_A1'});
                                app.peaksTable = [app.peaksTable; newRows];
                            end
                        end
                        % ---- A0 Detection Phase ----
                        requiredCount = app.i.Value;
                        if ~app.A0_detected && length(app.A2A1_differences) >= requiredCount
                            avgDiff = mean(app.A2A1_differences(1:requiredCount));
                            app.EventsTextArea.Value = [
                                app.EventsTextArea.Value
                                sprintf('Initial average A2-A1 (A0) detected: %.2f (based on first %d differences).', avgDiff, requiredCount)
                                'LED should be ON.'
                                ];
                            app.A0_detected = true;
                            app.SendEspRequest("/on");   % Turns LED on
                        end
                        % ---- Grouping and C Threshold Logic ----
                        while length(app.A2A1_differences) >= app.GROUP_SIZE
                            % Take first GROUP_SIZE, calculate average
                            group = app.A2A1_differences(1:app.GROUP_SIZE);
                            groupAvg = mean(group);
                            
                            % Remove those GROUP_SIZE from the buffer
                            app.A2A1_differences(1:app.GROUP_SIZE) = [];
                            
                            % Append to grouped means
                            app.groupedMeans = [app.groupedMeans; groupAvg];
                            app.groupCount = app.groupCount + 1;
                            
                            % Update grouped table
                            newRow = table(datetime('now'), groupAvg, app.groupCount, ...
                                'VariableNames', {'Timestamp', 'GroupMean', 'GroupNumber'});
                            app.groupedMeansTable = [app.groupedMeansTable; newRow];
                            
                            % Only compare if we have at least MIN_GROUPS_FOR_C_CHECK groups
                            if length(app.groupedMeans) >= app.MIN_GROUPS_FOR_C_CHECK
                                % Calculate average of the last MIN_GROUPS_FOR_C_CHECK groups
                                if length(app.groupedMeans) >= app.MIN_GROUPS_FOR_C_CHECK
                                    recentGroupsAvg = mean(app.groupedMeans(end - (app.MIN_GROUPS_FOR_C_CHECK - 1) : end)); % Average of last N groups including current
                                else
                                    recentGroupsAvg = mean(app.groupedMeans); % Average of all available groups
                                end
                                
                              % Comparison with C
            diffFromRecent = abs(groupAvg - recentGroupsAvg);
            
            if diffFromRecent < app.C.Value
                % It's less than C, now check if it's also less than 1
                if diffFromRecent < 1
                    % --- NEW LOGIC ---
                    % It's less than 1, consider it an anomaly and CONTINUE
                    app.EventsTextArea.Value = [
                        app.EventsTextArea.Value
                        sprintf('Anomaly: Δ (%.2f) < 1. Continuing therapy. Current Group Mean: %.2f', diffFromRecent, groupAvg)
                        ];
                    % We explicitly DO NOT call stopTherapyProcedure() here.
                    % --- END NEW LOGIC ---
                else
                    % It's less than C, but NOT less than 1. Stop therapy.
                    app.EventsTextArea.Value = [
                        app.EventsTextArea.Value
                        sprintf('Δ (%.2f) < C (%.2f) [but >= 1]. Significant change detected. Turning OFF LED and stopping therapy.', diffFromRecent, app.C.Value)
                        ];
                    app.stopTherapyProcedure(); % Stop the entire therapy
                    return; % Exit fetchAndPlot as therapy has stopped
                end
            else
                % It's >= C (and therefore >= 1, unless C < 1). Continue therapy.
                app.EventsTextArea.Value = [
                    app.EventsTextArea.Value
                    sprintf('Δ (%.2f) >= C (%.2f). Continuing therapy. Current Group Mean: %.2f', diffFromRecent, app.C.Value, groupAvg)
                    ];
            end
                            else
                                 app.EventsTextArea.Value = [
                                        app.EventsTextArea.Value
                                        sprintf('Collected group %d. Waiting for at least %d groups for C threshold check.', app.groupCount, app.MIN_GROUPS_FOR_C_CHECK)
                                        sprintf('Current Group Mean: %.2f', groupAvg)
                                        ];
                            end
                        end
                    end
                end
                % Plotting
                cla(app.UIAxes);
                plot(app.UIAxes, t, app.signalBuffer, 'b', 'DisplayName', 'Raw Signal');
                hold(app.UIAxes, 'on');
                % Plot smoothed signal
                plot(app.UIAxes, t, smoothedSignal, 'k--', 'DisplayName', 'Smoothed Signal');
                % Plot A2 peaks (red)
                plot(app.UIAxes, t(locs_max), app.signalBuffer(locs_max), 'ro', 'MarkerSize', 6, 'DisplayName', 'A2 Peak');
                text(app.UIAxes, t(locs_max), app.signalBuffer(locs_max) + app.PEAK_TEXT_OFFSET, 'A2', ...
                    'Color', 'r', 'FontSize', 9, 'VerticalAlignment', 'bottom', 'HorizontalAlignment', 'center');
                % Plot A1 valleys (green)
                plot(app.UIAxes, t(locs_min), app.signalBuffer(locs_min), 'go', 'MarkerSize', 6, 'DisplayName', 'A1 Valley');
                text(app.UIAxes, t(locs_min), app.signalBuffer(locs_min) - app.PEAK_TEXT_OFFSET, 'A1', ...
                    'Color', 'g', 'FontSize', 9, 'VerticalAlignment', 'top', 'HorizontalAlignment', 'center');
                % Axis labels and title
                xlabel(app.UIAxes, 'Time (s)');
                ylabel(app.UIAxes, 'Amplitude');
                % Title is updated by Connect/Start/Stop buttons
                legend(app.UIAxes, 'Location', 'southwest');
                grid(app.UIAxes, 'on');
                % Ensure ylim handles empty or very small signalBuffer
                if ~isempty(app.signalBuffer) && max(app.signalBuffer) > min(app.signalBuffer)
                    % Extend ylim to accommodate text offsets
                    ylim(app.UIAxes, [min(app.signalBuffer)-app.PEAK_TEXT_OFFSET-50, max(app.signalBuffer)+app.PEAK_TEXT_OFFSET+50]);
                else
                    ylim(app.UIAxes, [0 1023]); % Default range for ADC (0-1023 for 10-bit ADC) if no signal
                end
                hold(app.UIAxes, 'off');
                % Update index
                app.ipos = app.ipos + length(rawData);
            catch ME
                % Only log error if app is connected or therapy is running
                if app.isConnected || app.therapyRunning
                    app.EventsTextArea.Value = [app.EventsTextArea.Value; "Data processing or plotting error: " + ME.message];
                end
            end
        end
        function [matchedA1, matchedA2, matchedTimes, diffs] = matchPeaks(app, t, smoothedSignal, pks_min, locs_min, pks_max, locs_max)
            matchedA1 = [];
            matchedA2 = [];
            matchedTimes = [];
            diffs = [];
            if isempty(locs_min) || isempty(locs_max)
                return;
            end
            % Sort peaks by their time locations
            [locs_min_sorted, idx_min_sorted] = sort(locs_min);
            pks_min_sorted = pks_min(idx_min_sorted);
            [locs_max_sorted, idx_max_sorted] = sort(locs_max);
            pks_max_sorted = pks_max(idx_max_sorted);

            % Iterate through sorted minima (A1 valleys)
            for i = 1:length(locs_min_sorted)
                current_A1_loc = locs_min_sorted(i);
                current_A1_val = pks_min_sorted(i);

                % Define the search window for A2: from current A1 up to the next A1 or end of signal
                if i < length(locs_min_sorted)
                    next_A1_loc = locs_min_sorted(i+1);
                    search_end_loc = next_A1_loc;
                else
                    search_end_loc = length(smoothedSignal); % Search to end of signal if last A1
                end

                % Find all maxima that occur after the current A1 and within the search window
                potential_A2_indices = find(locs_max_sorted > current_A1_loc & locs_max_sorted < search_end_loc);
                
                if ~isempty(potential_A2_indices)
                    % From these potential A2s, find the one with the maximum amplitude
                    [peak_A2_val, peak_A2_idx_in_potential] = max(pks_max_sorted(potential_A2_indices));
                    
                    % Get the global index of the selected A2
                    selected_A2_global_loc_idx = potential_A2_indices(peak_A2_idx_in_potential);
                    selected_A2_loc = locs_max_sorted(selected_A2_global_loc_idx);

                    % Add to matched lists
                    matchedA1 = [matchedA1; current_A1_val];
                    matchedA2 = [matchedA2; peak_A2_val];
                    matchedTimes = [matchedTimes; t(selected_A2_loc)]; % Time of the selected A2
                    diffs = [diffs; (peak_A2_val - current_A1_val) / 100]; % Divided by 100
                end
            end
            % Ensure outputs are column vectors
            matchedA1 = matchedA1(:);
            matchedA2 = matchedA2(:);
            matchedTimes = matchedTimes(:);
            diffs = diffs(:);
        end
    end
    % Component initialization
    methods (Access = private)
        % Create UIFigure and components
        function createComponents(app)
            % Create BnuUIFigure and hide until all components are created
            app.BnuUIFigure = uifigure('Visible', 'off');
            app.BnuUIFigure.Position = [100 100 834 611];
            app.BnuUIFigure.Name = 'PPG Signal Analyzer';
            app.BnuUIFigure.CloseRequestFcn = createCallbackFcn(app, @delete, true); % Handle app closing
            % Create UIAxes
            app.UIAxes = uiaxes(app.BnuUIFigure);
            title(app.UIAxes, 'PPG Signal (Disconnected)') % Initial title
            xlabel(app.UIAxes, 'Time (s)')
            ylabel(app.UIAxes, 'Amplitude')
            app.UIAxes.Position = [28 162 788 210];
            app.UIAxes.XGrid = 'on';
            app.UIAxes.YGrid = 'on';
            % Create ConnectButton
            app.ConnectButton = uibutton(app.BnuUIFigure, 'push');
            app.ConnectButton.ButtonPushedFcn = createCallbackFcn(app, @ConnectButtonPushed, true);
            app.ConnectButton.Position = [22 535 132 43];
            app.ConnectButton.Text = 'Connect';
            app.ConnectButton.BackgroundColor = [0.8 0.8 0.8]; % Default gray
            % Create StartTherapyButton
            app.StartTherapyButton = uibutton(app.BnuUIFigure, 'push');
            app.StartTherapyButton.ButtonPushedFcn = createCallbackFcn(app, @StartTherapyButtonPushed, true);
            app.StartTherapyButton.Position = [23 460 133 45];
            app.StartTherapyButton.Text = 'Start Therapy';
            app.StartTherapyButton.Enable = 'off'; % Disabled by default
            % Create StopButton
            app.StopButton = uibutton(app.BnuUIFigure, 'push');
            app.StopButton.ButtonPushedFcn = createCallbackFcn(app, @StopButtonPushed, true);
            app.StopButton.Position = [25 392 129 47];
            app.StopButton.Text = 'Stop Therapy';
            app.StopButton.Enable = 'off'; % Disabled by default
            % Create Label (Elapsed Time)
            app.Label = uilabel(app.BnuUIFigure);
            app.Label.Position = [238 517 156 44];
            app.Label.Text = 'Elapsed Time: 0 sec';
            app.Label.FontSize = 14;
            % Create Label_i
            app.Label_i = uilabel(app.BnuUIFigure);
            app.Label_i.HorizontalAlignment = 'right';
            app.Label_i.Position = [224 507 155 30];
            app.Label_i.Text = {'Number of A2-A1 diffs for A0'; 'detection:'; ''};
            app.Label_i.Tooltip = 'Number of initial A2-A1 differences to average for the A0 baseline.';
            % Create i (NumericEditField)
            app.i = uieditfield(app.BnuUIFigure, 'numeric');
            app.i.HorizontalAlignment = 'center';
            app.i.Position = [393 504 40 44];
            app.i.Value = 5;
            app.i.Limits = [1 Inf]; % Must be at least 1
            % Create Label_4 (C threshold)
            app.Label_4 = uilabel(app.BnuUIFigure);
            app.Label_4.HorizontalAlignment = 'right';
            app.Label_4.Position = [229 426 150 22];
            app.Label_4.Text = 'Significance Threshold C:';
            app.Label_4.Tooltip = 'If the absolute difference between the current grouped average and the average of the previous 5 grouped averages is less than C, therapy stops.';
            % Create C (NumericEditField)
            app.C = uieditfield(app.BnuUIFigure, 'numeric');
            app.C.HorizontalAlignment = 'center';
            app.C.Position = [393 413 40 49];
            app.C.Value = 3;
            app.C.Limits = [0 Inf]; % Must be non-negative
            % Create Label_5 (T1)
            app.Label_5 = uilabel(app.BnuUIFigure);
            app.Label_5.HorizontalAlignment = 'right';
            app.Label_5.Position = [510 512 244 22];
            app.Label_5.Text = 'Min. Therapy Duration (minutes):';
            app.Label_5.Tooltip = 'Minimum time (in minutes) the therapy must run before checking for significant changes.';
            % Create T1 (NumericEditField)
            app.T1 = uieditfield(app.BnuUIFigure, 'numeric');
            app.T1.HorizontalAlignment = 'center';
            app.T1.Position = [770 499 29 49];
            app.T1.Value = 5; % Default value
            app.T1.Limits = [0 Inf];
            % Create Label_6 (T2)
            app.Label_6 = uilabel(app.BnuUIFigure);
            app.Label_6.HorizontalAlignment = 'right';
            app.Label_6.Position = [512 439 240 22];
            app.Label_6.Text = 'Max. Therapy Duration (minutes):';
            app.Label_6.Tooltip = 'Maximum time (in minutes) the therapy will run before automatically stopping.';
            % Create T2 (NumericEditField)
            app.T2 = uieditfield(app.BnuUIFigure, 'numeric');
            app.T2.HorizontalAlignment = 'center';
            app.T2.Position = [770 426 29 47];
            app.T2.Value = 20; % Default value
            app.T2.Limits = [0 Inf];
            % Create EventsTextAreaLabel
            app.EventsTextAreaLabel = uilabel(app.BnuUIFigure);
            app.EventsTextAreaLabel.HorizontalAlignment = 'right';
            app.EventsTextAreaLabel.Position = [25 107 42 22];
            app.EventsTextAreaLabel.Text = 'Events:';
            % Create EventsTextArea
            app.EventsTextArea = uitextarea(app.BnuUIFigure);
            app.EventsTextArea.Position = [82 15 734 116];
            app.EventsTextArea.Editable = false; % Make it read-only
            app.EventsTextArea.Value = 'Application started. Connect to device.';
            % Show the figure after all components are created
            app.BnuUIFigure.Visible = 'on';
        end
    end
    % App creation and deletion
    methods (Access = public)
        % Construct app
        function app = Bnu1
            % Create UIFigure and components
            createComponents(app)
            % Register the app with App Designer
            registerApp(app, app.BnuUIFigure)
            if nargout == 0
                clear app
            end
        end
        % Code that executes before app deletion
        function delete(app)
            % Stop and delete timers
            app.stopTimers();
            % Disconnect COM object if connected
            if ~isempty(app.pdev)
                try
                    app.pdev.Disconnect();
                catch ME
                    disp(['Error disconnecting COM object: ' ME.message]);
                end
            end
            % Delete UIFigure when app is deleted
            delete(app.BnuUIFigure)
        end
    end
end