import FirebaseMessaging
import Firebase
import PizzaKit
import Combine
import Defaults

public enum PizzaFirebasePushNotificationTopicsManagerError: Error {
    case notAllTopicsChanged(
        notSubscribed: Set<String>,
        notUnsubscribed: Set<String>
    )
    case unknownTopic
    case firebase(Error)
}

// TODO: subscribeAtFirstLaunch тоже подписаться
public typealias PizzaFirebasePushNotificationTopicsManagerPublisher = AnyPublisher<
    Void,
    PizzaFirebasePushNotificationTopicsManagerError
>

public protocol PizzaFirebasePushNotificationTopicsManager {

    @available(*, deprecated, renamed: "init(allTopics:subscribeAtFirstLaunch:)", message: "use new initializer instead")
    init(allTopics: [String])
    
    init(allTopics: [String], subscribeAtFirstLaunch: [String])

    // Текущие подписанные топики
    var subscribedTopicsPublisher: PizzaRPublisher<Set<String>, Never> { get }
    // Состояние - загрузка (true) или не загрузка (false)
    var subscribingLoadingPublisher: PizzaRPublisher<Bool, Never> { get }

    func subscribeAll()
    func subscribeAllPublisher() -> PizzaFirebasePushNotificationTopicsManagerPublisher

    func unsubscribeAll()
    func unsubscribeAllPublisher() -> PizzaFirebasePushNotificationTopicsManagerPublisher

    func subscribe(to topic: String)
    func subscribePublisher(to topic: String) -> PizzaFirebasePushNotificationTopicsManagerPublisher

    func subscribe(to topics: [String])
    func subscribePublisher(to topics: [String]) -> PizzaFirebasePushNotificationTopicsManagerPublisher

    func unsubscribe(from topic: String)
    func unsubscribePublisher(from topic: String) -> PizzaFirebasePushNotificationTopicsManagerPublisher
}

public class PizzaFirebasePushNotificationTopicsManagerImpl: PizzaFirebasePushNotificationTopicsManager {

    private typealias ManagerError = PizzaFirebasePushNotificationTopicsManagerError
    private actor State {
        var progressSubscribeTopics: [String] = []
        var progressUnsubscribeTopics: [String] = []
    }

    // MARK: - Properties

    private var state: State = .init()

    public let allAvailableTopics: Set<String>
    public let subscribeAtFirstLaunch: Set<String>

    public var subscribedTopicsPublisher: PizzaRPublisher<Set<String>, Never> {
        subscribedTopicsRWPublisher
    }
    public var subscribingLoadingPublisher: PizzaRPublisher<Bool, Never> {
        PizzaCurrentValueRPublisher(subject: subscribingLoadingSubject)
    }
    
    private let subscribedTopicsRWPublisher = PizzaPassthroughRWPublisher<Set<String>, Never>(
        currentValue: {
            return Set(Defaults[.subscribedTopics])
        },
        onValueChanged: { newTopics in
            Defaults[.subscribedTopics] = Array(newTopics)
        }
    )
    private let subscribingLoadingSubject: CurrentValueSubject<Bool, Never> = .init(false)

    private var bag = Set<AnyCancellable>()

    private var taskQueue = TaskQueue()

    // MARK: - Initialization

    public required init(allTopics: [String], subscribeAtFirstLaunch: [String]) {
        self.allAvailableTopics = Set(allTopics)
        self.subscribeAtFirstLaunch = Set(subscribeAtFirstLaunch)

        // Логгируем топики (текущие и новые) при изменении
        subscribedTopicsRWPublisher
            .withoutCurrentValue
            .removeDuplicates()
            .sink { topics in
//                print("$$$ current topics \(topics)")
                PizzaLogger.log(
                    label: "push_topics",
                    level: .info,
                    message: "Topics updated",
                    payload: [
                        "new_topics": Array(topics)
                    ]
                )
            }
            .store(in: &bag)
        PizzaLogger.log(
            label: "push_topics",
            level: .info,
            message: "Initial topics",
            payload: [
                "topics": Array(subscribedTopicsRWPublisher.value)
            ]
        )

        let completion: () -> Void = { [weak self] in
            guard let self else { return }

            self.refreshSubscriptions()
            NotificationCenter.default
                .publisher(for: .pushTokenUpdated)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] output in
                    self?.refreshSubscriptions()
                }
                .store(in: &self.bag)

            NotificationCenter
                .default
                .publisher(for: UIApplication.didBecomeActiveNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.refreshSubscriptions()
                }
                .store(in: &self.bag)
        }

        if !Defaults[.wasFirstTopicsSubscription] {
            subscribePublisher(to: subscribeAtFirstLaunch)
                .receive(on: DispatchQueue.main)
                .sink { _ in
                    completion()
                } receiveValue: { _ in
                    Defaults[.wasFirstTopicsSubscription] = true
                }
                .store(in: &bag)
        } else {
            completion()
        }
    }

    @available(*, deprecated, renamed: "init(allTopics:subscribeAtFirstLaunch:)", message: "use new initializer instead")
    public required convenience init(allTopics: [String]) {
        self.init(allTopics: allTopics, subscribeAtFirstLaunch: [])
    }

    // MARK: - Methods

    public func subscribeAll() {
        subscribeAllPublisher()
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { _ in }
            )
            .store(in: &bag)
    }

    public func subscribeAllPublisher() -> PizzaFirebasePushNotificationTopicsManagerPublisher {
        handle(
            targetTopics: allAvailableTopics,
            isSubscription: true
        )
    }

    public func unsubscribeAll() {
        unsubscribeAllPublisher()
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { _ in }
            )
            .store(in: &bag)
    }

    public func unsubscribeAllPublisher() -> PizzaFirebasePushNotificationTopicsManagerPublisher {
        handle(
            targetTopics: allAvailableTopics,
            isSubscription: false
        )
    }

    public func subscribe(to topic: String) {
        subscribePublisher(to: topic)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { _ in }
            )
            .store(in: &bag)
    }

    public func subscribePublisher(to topic: String) -> PizzaFirebasePushNotificationTopicsManagerPublisher {
        handle(
            targetTopics: Set([topic]),
            isSubscription: true
        )
    }

    public func subscribe(to topics: [String]) {
        subscribePublisher(to: topics)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { _ in }
            )
            .store(in: &bag)
    }

    public func subscribePublisher(to topics: [String]) -> PizzaFirebasePushNotificationTopicsManagerPublisher {
        handle(
            targetTopics: Set(topics),
            isSubscription: true
        )
    }

    public func unsubscribe(from topic: String) {
        unsubscribePublisher(from: topic)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { _ in }
            )
            .store(in: &bag)
    }

    public func unsubscribePublisher(from topic: String) -> PizzaFirebasePushNotificationTopicsManagerPublisher {
        handle(
            targetTopics: Set([topic]),
            isSubscription: false
        )
    }

    // MARK: - Private Methods

    private func refreshSubscriptions() {
        PizzaPushNotificationsPermissionHelper.getCurrentPermission { [weak self] isGranted in
            DispatchQueue.main.async {
                guard let self else { return }
                if
                    isGranted,
                    !Defaults[.wasResubscribedAfterPermissionGranted],
                    Messaging.messaging().apnsToken != nil
                {
                    let subscribeTopics = Array(self.subscribedTopicsRWPublisher.value)
                    self.unsubscribeAllPublisher()
                        .flatMap { [weak self] _ -> AnyPublisher<Void, ManagerError> in
                            guard let self else {
                                return Empty().eraseToAnyPublisher()
                            }
                            return self.subscribePublisher(to: subscribeTopics)
                        }
                        .receive(on: DispatchQueue.main)
                        .sink { _ in
                        } receiveValue: { [weak self] _ in
                            Defaults[.wasResubscribedAfterPermissionGranted] = true
                        }
                        .store(in: &self.bag)
                }
                if isGranted == false {
                    Defaults[.wasResubscribedAfterPermissionGranted] = false
                }
            }
        }
    }

    private func handle(
        targetTopics: Set<String>,
        isSubscription: Bool
    ) async throws {
        let unknownTopics = targetTopics.subtracting(allAvailableTopics)
        guard unknownTopics.isEmpty else {
            PizzaLogger.log(
                label: "push_topics",
                level: .info,
                message: "Unknown topics tried to subscribe/unsubscribe \(isSubscription)",
                payload: [
                    "targetTopics": Array(targetTopics)
                ]
            )
            throw ManagerError.unknownTopic
        }

        let expectedTargetTopics = {
            if isSubscription {
                return subscribedTopicsRWPublisher.value.union(targetTopics)
            } else {
                return subscribedTopicsRWPublisher.value.subtracting(targetTopics)
            }
        }()

        for topic in targetTopics {
            if isSubscription {
                try await subscribeTo(topic: topic)
            } else {
                try await unsubscribeFrom(topic: topic)
            }
        }

        let currentTopics = subscribedTopicsRWPublisher.value
        if currentTopics != expectedTargetTopics {
            throw ManagerError.notAllTopicsChanged(
                notSubscribed: expectedTargetTopics.subtracting(currentTopics),
                notUnsubscribed: currentTopics.subtracting(expectedTargetTopics)
            )
        }
    }

    private func subscribeTo(topic: String) async throws {
//        print("$$$ subscribe to \(topic)")
        if subscribedTopicsRWPublisher.value.contains(topic) {
            subscribedTopicsRWPublisher.value.insert(topic)
            await withCheckedContinuation { cont in
                PizzaPushNotificationsPermissionHelper.getCurrentPermission { isGranted in
                    if isGranted && Messaging.messaging().apnsToken != nil {
//                        print("$$$ real subscribe to \(topic)")
                        Messaging.messaging().subscribe(
                            toTopic: topic,
                            completion: { [weak self] _ in
                                self?.subscribedTopicsRWPublisher.value.insert(topic)
                                cont.resume()
                            }
                        )
                    } else {
                        cont.resume()
                    }
                }
            }
        } else {
            subscribedTopicsRWPublisher.value.insert(topic)
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                PizzaPushNotificationsPermissionHelper.getCurrentPermission { isGranted in
                    if isGranted && Messaging.messaging().apnsToken != nil {
//                        print("$$$ real subscribe to \(topic)")
                        Messaging.messaging().subscribe(
                            toTopic: topic,
                            completion: { [weak self] error in
                                if let error {
                                    self?.subscribedTopicsRWPublisher.value.remove(topic)
                                    cont.resume(throwing: error)
                                } else {
                                    self?.subscribedTopicsRWPublisher.value.insert(topic)
                                    cont.resume()
                                }
                            }
                        )
                    } else {
                        cont.resume()
                    }
                }
            }
        }
    }

    private func unsubscribeFrom(topic: String) async throws {
//        print("$$$ unsubscribe from \(topic)")
        if !subscribedTopicsRWPublisher.value.contains(topic) {
            subscribedTopicsRWPublisher.value.remove(topic)
            await withCheckedContinuation { cont in
                PizzaPushNotificationsPermissionHelper.getCurrentPermission { isGranted in
                    if isGranted && Messaging.messaging().apnsToken != nil {
//                        print("$$$ real unsubscribe from \(topic)")
                        Messaging.messaging().unsubscribe(
                            fromTopic: topic,
                            completion: { [weak self] _ in
                                self?.subscribedTopicsRWPublisher.value.remove(topic)
                                cont.resume()
                            }
                        )
                    } else {
                        cont.resume()
                    }
                }
            }
        } else {
            subscribedTopicsRWPublisher.value.remove(topic)
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                PizzaPushNotificationsPermissionHelper.getCurrentPermission { isGranted in
                    if isGranted && Messaging.messaging().apnsToken != nil {
//                        print("$$$ real unsubscribe from \(topic)")
                        Messaging.messaging().unsubscribe(
                            fromTopic: topic,
                            completion: { [weak self] error in
                                if let error {
                                    self?.subscribedTopicsRWPublisher.value.insert(topic)
                                    cont.resume(throwing: error)
                                } else {
                                    self?.subscribedTopicsRWPublisher.value.remove(topic)
                                    cont.resume()
                                }
                            }
                        )
                    } else {
                        cont.resume()
                    }
                }
            }
        }
    }

    private func handle(
        targetTopics: Set<String>,
        isSubscription: Bool
    ) -> PizzaFirebasePushNotificationTopicsManagerPublisher {
        let subject = PassthroughSubject<Void, ManagerError>()

        taskQueue.dispatch {
            self.subscribingLoadingSubject.send(true)

            do {
                try await self.handle(
                    targetTopics: targetTopics,
                    isSubscription: isSubscription
                )
                subject.send(())
                subject.send(completion: .finished)
            } catch let error as ManagerError {
                subject.send(completion: .failure(error))
            } catch {
                subject.send(completion: .failure(.firebase(error)))
            }

            self.subscribingLoadingSubject.send(false)
        }

        return subject.eraseToAnyPublisher()
    }

}

fileprivate extension Defaults.Keys {
    static let subscribedTopics = Defaults.Key<[String]>("push_firebase_subscribed_topics", default: [])
    static let wasFirstTopicsSubscription = Defaults.Key<Bool>("push_firebase_wasFirstTopicsSubscription", default: false)
    static let wasResubscribedAfterPermissionGranted = Defaults.Key<Bool>("push_firebase_wasResubscribedAfterPermissionGranted", default: false)
}

private class TaskQueue {

    private actor TaskQueueActor{
        private var blocks : [() async -> Void] = []
        private var currentTask : Task<Void,Never>? = nil

        func addBlock(block: @escaping () async -> Void) {
            blocks.append(block)
            next()
        }

        func next() {
            if (currentTask != nil) {
                return
            }
            if (!blocks.isEmpty) {
                let block = blocks.removeFirst()
                currentTask = Task {
                    await block()
                    currentTask = nil
                    next()
                }
            }
        }
    }
    private let taskQueueActor = TaskQueueActor()

    func dispatch(block: @escaping () async ->Void) {
        Task{
            await taskQueueActor.addBlock(block: block)
        }
    }
}
