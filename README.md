PPG Signal Analyzer and Therapy Monitor
A MATLAB application for real-time analysis of PPG signals and automated therapy monitoring. This app connects to a device, processes PPG data, detects peak differences (A2-A1), and controls therapy duration and thresholds based on dynamic signal behavior.

 Features

Device Connectivity : Connects to external hardware via COM interface.

Real-Time Signal Plotting : Visualizes raw and smoothed PPG signals with detected A1 valleys and A2 peaks.

Therapy Timer Control : Start/stop therapy with user-defined minimum and maximum durations (T1 and T2).

Automatic Threshold Detection : Calculates baseline A0 from initial A2-A1 differences.

Dynamic Group Analysis : Monitors changes in grouped A2-A1 differences using threshold C.

ESP Integration : Communicates with an ESP module to control LED status during therapy.<br>

Data Logging : Automatically saves A2-A1 difference logs into timestamped CSV files.<br>

 Requirements

MATLAB R2020a or later

Pulse.CoDevice COM object (for hardware communication)

ESP32 or similar microcontroller (optional for LED control)

PPG sensor hardware with appropriate drivers and connectivity


 Usage

Connect Hardware : Ensure your PPG device is connected and recognized by the system.

Launch App : Open Bnu1.mlapp in MATLAB.

Connect Device : Click "Connect" to establish communication.

Configure Settings :

Set T1 (minimum therapy time) and T2 (maximum therapy time).

Set threshold C for detecting significant change in signal patterns.

Start Therapy : Press "Start Therapy" to begin signal acquisition and analysis.

Monitor Events : View log messages and elapsed time in the UI.

Stop Therapy : Either manually stop or wait until T2 or a significant change is detected.

Data Export : Logs are automatically saved after each session.


 Notes
The app assumes a specific hardware interface (Pulse.CoDevice). You may need to adapt this for your specific setup.
Communication with ESP is optional but allows visual feedback via LED (ON/OFF).
All data is saved as .csv files with timestamps for easy post-processing.
