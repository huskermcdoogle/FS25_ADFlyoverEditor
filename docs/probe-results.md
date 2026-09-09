# Probe results — raw log evidence

Captured from the FS25 `log.txt` of 2026-09-08, running stock AutoDrive 3.0.0.8 with
FS25_AutoDrive_Gibbs disabled, savegame2 (Riverbend Springs, 17,174 waypoints).
FS25 truncates its log on every launch, so this is the durable copy of the evidence cited by
`companion-mod-investigation.md` and `companion-build-plan.md`.

The mod that produced it, `FS25_FlyoverProxySpike`, was a throwaway. It has done its job — every
mechanism it proved is now carried by `FS25_ADFlyoverEditor` — and has been uninstalled. This file is
what survives it, which is the part that mattered.

```
Available mod:  (Version: 0.1.0.0) FS25_FlyoverProxySpike
03:51:00.961   Load mod: FS25_FlyoverProxySpike
03:51:50.646   Info: [AutoDrive] Loaded mod version 3.0.0.8 (by Stephan). Full version number: 3.0.0.8
03:51:54.762   Info: [FlyoverProxySpike] looking for AutoDrive's specialization table...
03:51:54.762   Info: [FlyoverProxySpike]   route nil     plain global 'AutoDrive' in our own mod environment
03:51:54.762   Info: [FlyoverProxySpike]   route nil     getfenv(0).AutoDrive (true root environment)
03:51:54.762   Info: [FlyoverProxySpike]   route nil     g_specializationManager:getSpecializationByName('AutoDrive')
03:51:54.762   Info: [FlyoverProxySpike]   route WORKS   scan g_vehicleTypeManager types for the onDrawUIInfo listener
03:51:54.762   Info: [FlyoverProxySpike] armed - hooks installed on isEditorShowEnabled, onDrawUIInfo and draw.
03:51:54.762   Info: [FlyoverProxySpike] run 'ADProxySpike' while in a vehicle near your route network to toggle the test.
03:53:03.612 Console command: ADProxySpikeEnv 
03:53:03.612   Info: [FlyoverProxySpike] environment probe - looking for the 8 globals a full port needs:
03:53:03.612   Info: [FlyoverProxySpike]   getfenv(0) - true root (control)             -> 0/8 needed, 1 AD* tables total
03:53:03.612   Info: [FlyoverProxySpike]         missing: ADGraphManager, ADDrawingManager, ADEnterTargetNameGui, ADCollSensor, AutoDrive, ADInputManager, ADMessagesManager, ADRoutesManager
03:53:03.612   Info: [FlyoverProxySpike]         all AD*: ADFlyoverProxySpike
03:53:03.612   Info: [FlyoverProxySpike]   getfenv(AutoDrive.onDrawEditorMode)          -> 8/8 needed, 49 AD* tables total
03:53:03.612   Info: [FlyoverProxySpike]         found:   ADGraphManager, ADDrawingManager, ADEnterTargetNameGui, ADCollSensor, AutoDrive, ADInputManager, ADMessagesManager, ADRoutesManager
03:53:03.612   Info: [FlyoverProxySpike]         all AD*: ADCollSensor, ADCollSensorSplit, ADCollisionDetectionModule, ADColorSettingsGui, ADDebugSettingsPage, ADDimensionSensor, ADDrawingManager, ADDrivePathModule, ADDubins, ADEnterDestinationFilterGui, ADEnterDriverNameGui, ADEnterGroupNameGui, ADEnterTargetNameGui, ADFieldSensor, ADFruitSensor, ADGenericHudElement, ADGenericHudElement_mt, ADGraphManager, ADGuiDebugMixin, ADHarvestManager, ADHudButton, ADHudCounterButton, ADHudIcon, ADHudSettingsButton, ADHudSpeedmeter, ADInputManager, ADMessagesManager, ADMultipleTargetsManager, ADNotificationsHistoryGui, ADPathCalculator, ADPullDownList, ADRecordingModule, ADRoutesManager, ADRoutesManagerGui, ADScanConfirmationGui, ADScheduler, ADSensor, ADSensor_mt, ADSettings, ADSettingsPage, ADSpecialDrivingModule, ADStateModule, ADTaskModule, ADTrailerModule, ADTrainModule, ADTriggerManager, ADUnloadManager, ADUserDataManager, ADVectorUtils
03:53:03.612   Info: [FlyoverProxySpike]   getfenv(AutoDrive.getSetting)                -> 8/8 needed, 49 AD* tables total
03:53:03.612   Info: [FlyoverProxySpike]         found:   ADGraphManager, ADDrawingManager, ADEnterTargetNameGui, ADCollSensor, AutoDrive, ADInputManager, ADMessagesManager, ADRoutesManager
03:53:03.612   Info: [FlyoverProxySpike]         all AD*: ADCollSensor, ADCollSensorSplit, ADCollisionDetectionModule, ADColorSettingsGui, ADDebugSettingsPage, ADDimensionSensor, ADDrawingManager, ADDrivePathModule, ADDubins, ADEnterDestinationFilterGui, ADEnterDriverNameGui, ADEnterGroupNameGui, ADEnterTargetNameGui, ADFieldSensor, ADFruitSensor, ADGenericHudElement, ADGenericHudElement_mt, ADGraphManager, ADGuiDebugMixin, ADHarvestManager, ADHudButton, ADHudCounterButton, ADHudIcon, ADHudSettingsButton, ADHudSpeedmeter, ADInputManager, ADMessagesManager, ADMultipleTargetsManager, ADNotificationsHistoryGui, ADPathCalculator, ADPullDownList, ADRecordingModule, ADRoutesManager, ADRoutesManagerGui, ADScanConfirmationGui, ADScheduler, ADSensor, ADSensor_mt, ADSettings, ADSettingsPage, ADSpecialDrivingModule, ADStateModule, ADTaskModule, ADTrailerModule, ADTrainModule, ADTriggerManager, ADUnloadManager, ADUserDataManager, ADVectorUtils
03:53:03.612   Info: [FlyoverProxySpike]   getfenv(AutoDrive.draw)                      -> 0/8 needed, 1 AD* tables total
03:53:03.612   Info: [FlyoverProxySpike]         missing: ADGraphManager, ADDrawingManager, ADEnterTargetNameGui, ADCollSensor, AutoDrive, ADInputManager, ADMessagesManager, ADRoutesManager
03:53:03.612   Info: [FlyoverProxySpike]         all AD*: ADFlyoverProxySpike
03:53:03.612   Info: [FlyoverProxySpike]   getfenv(AutoDrive.isEditorShowEnabled)       -> 0/8 needed, 1 AD* tables total
03:53:03.612   Info: [FlyoverProxySpike]         missing: ADGraphManager, ADDrawingManager, ADEnterTargetNameGui, ADCollSensor, AutoDrive, ADInputManager, ADMessagesManager, ADRoutesManager
03:53:03.612   Info: [FlyoverProxySpike]         all AD*: ADFlyoverProxySpike
03:53:03.612   Info: [FlyoverProxySpike] ALL needed globals reachable - the editor files can be copied across unchanged.
```
