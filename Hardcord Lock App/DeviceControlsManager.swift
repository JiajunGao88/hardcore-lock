import DeviceActivity
import ManagedSettings
import FamilyControls

final class DeviceActivityManager {
    static let shared = DeviceActivityManager()
    
    private let center = DeviceActivityCenter()
    private let store = ManagedSettingsStore()
    
    private init() {}
    
    // MARK: - Start Blocking
    
    func startBlocking(
        apps: FamilyActivitySelection,
        duration: TimeInterval
    ) throws {
        // Create activity name
        let activityName = DeviceActivityName("HardcoreLock")
        
        // Calculate end time
        let now = Date()
        let endDate = now.addingTimeInterval(duration)
        
        // Create schedule
        let schedule = DeviceActivitySchedule(
            intervalStart: Calendar.current.dateComponents([.hour, .minute, .second], from: now),
            intervalEnd: Calendar.current.dateComponents([.hour, .minute, .second], from: endDate),
            repeats: false
        )
        
        // Start monitoring
        try center.startMonitoring(activityName, during: schedule)
        
        // Apply shield to selected apps
        store.shield.applications = apps.applicationTokens
        store.shield.applicationCategories = .specific(apps.categoryTokens)
        store.shield.webDomainCategories = .specific(apps.categoryTokens)
    }
    
    // MARK: - Stop Blocking (Emergency only - not exposed in UI)
    
    func stopBlocking() {
        let activityName = DeviceActivityName("HardcoreLock")
        center.stopMonitoring([activityName])
        
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        store.shield.webDomainCategories = nil
    }
}
