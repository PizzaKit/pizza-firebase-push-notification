import UIKit
import UserNotifications
import FirebaseMessaging
import PizzaKit
import Combine

/// Class for manipulating with pushNotification delegates
public class PizzaFirebasePushNotificationManager: NSObject, MessagingDelegate, UNUserNotificationCenterDelegate, PizzaPushNotificationManager {

    // MARK: - Private Properties

    private var bag = Set<AnyCancellable>()

    // MARK: - Initialization

    public override init() {
        super.init()

        UNUserNotificationCenter.current().delegate = self
        Messaging.messaging().delegate = self
        PizzaPushNotificationsPermissionHelper.requestAuthorization { _ in
            self.checkPermission()
        }

        NotificationCenter
            .default
            .publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.checkPermission()
            }
            .store(in: &bag)
    }

    // MARK: - PizzaPushNotificationManager

    public func didReceiveBackgroundNotification(userInfo: [AnyHashable : Any]) {
        Messaging.messaging().appDidReceiveMessage(userInfo)
    }

    public func didRegisterRemoteNotifications(with tokenData: Data) {
        Messaging.messaging().apnsToken = tokenData
    }

    // MARK: - MessagingDelegate

    public func messaging(
        _ messaging: Messaging,
        didReceiveRegistrationToken fcmToken: String?
    ) {
        print("FCM token: \(fcmToken ?? "<none>")")

        PizzaLogger.log(
            label: "push",
            level: .info,
            message: "Firebase messaging token received",
            payload: [
                "token": fcmToken as Any
            ]
        )

        let dataDict: [String: String] = ["token": fcmToken ?? ""]
        NotificationCenter.default.post(
            name: .pushTokenUpdated,
            object: nil,
            userInfo: dataDict
        )
    }

    // MARK: - UNUserNotificationCenterDelegate

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo

        Messaging.messaging().appDidReceiveMessage(userInfo)

        // Change this to your preferred presentation option
        completionHandler([.alert, .sound, .badge])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        Messaging.messaging().appDidReceiveMessage(userInfo)

        PizzaLogger.log(
            label: "push",
            level: .info,
            message: "Push notification received",
            payload: (userInfo as? [String: Any]) ?? [:]
        )

        if
            let targetScene = response.targetScene as? UIWindowScene,
            let sceneDelegate = targetScene.delegate as? PizzaSceneDelegateNotificationResponseHandler
        {
            sceneDelegate.handle(notificationResponse: response)
        }

        // clear badge number
        UIApplication.shared.applicationIconBadgeNumber = 0

        completionHandler()
    }

    // MARK: - Private Methods

    private func checkPermission() {
        PizzaPushNotificationsPermissionHelper.getCurrentPermission { isGranted in
            if isGranted {
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        }
    }

}

public extension Notification.Name {

    static let pushTokenUpdated = Notification.Name("FIRTokenUpdated")

}
