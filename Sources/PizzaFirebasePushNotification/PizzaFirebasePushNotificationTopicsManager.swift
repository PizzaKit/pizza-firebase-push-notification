import FirebaseMessaging
import Firebase
import PizzaKit
import Combine
import Defaults

public enum PizzaFirebasePushNotificationTopicsManagerError: Error {
    case notAllTopicsChanged(unchanged: Set<String>)
    case unknownTopic
}

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

    // MARK: - Properties

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
            PizzaLogger.log(
                label: "push_topics",
                level: .info,
                message: "Topics updated",
                payload: [
                    "new_topics": Array(newTopics)
                ]
            )
        }
    )
    private let subscribingLoadingSubject: CurrentValueSubject<Bool, Never> = .init(false)

    private var bag = Set<AnyCancellable>()

    // MARK: - Initialization

    public required init(allTopics: [String], subscribeAtFirstLaunch: [String]) {
        self.allAvailableTopics = Set(allTopics)
        self.subscribeAtFirstLaunch = Set(subscribeAtFirstLaunch)

        // Вдруг уже есть токен (то есть мы инициализировали сервис после того как токен был получен)
        if Messaging.messaging().apnsToken != nil {
            checkFirstSubscription()
        } else {
            NotificationCenter.default
                .publisher(for: .pushTokenUpdated)
                .first()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] output in
                    self?.checkFirstSubscription()
                }
                .store(in: &bag)
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

    private func checkFirstSubscription() {
        if !Defaults[.wasFirstTopicsSubscription] && !subscribeAtFirstLaunch.isEmpty {
            subscribePublisher(to: Array(subscribeAtFirstLaunch))
                .sink(
                    receiveCompletion: { _ in },
                    receiveValue: { _ in
                        Defaults[.wasFirstTopicsSubscription] = true
                    }
                )
                .store(in: &bag)
        }
    }

    private func handle(
        targetTopics: Set<String>,
        isSubscription: Bool
    ) -> PizzaFirebasePushNotificationTopicsManagerPublisher {
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
            return Fail(
                outputType: Void.self,
                failure: PizzaFirebasePushNotificationTopicsManagerError.unknownTopic
            ).eraseToAnyPublisher()
        }

        let subject = PassthroughSubject<Void, PizzaFirebasePushNotificationTopicsManagerError>()
        subscribingLoadingSubject.send(true)
        let group = DispatchGroup()

        var errorTopics = Set<String>()
        targetTopics.forEach { topic in


            if isSubscription {
                if !subscribedTopicsRWPublisher.value.contains(topic) {
                    group.enter()
                    subscribedTopicsRWPublisher.value.insert(topic)
                    Messaging.messaging().subscribe(
                        toTopic: topic,
                        completion: { [weak self] error in
                            if error != nil {
                                errorTopics.insert(topic)
                                self?.subscribedTopicsRWPublisher.value.remove(topic)
                            }
                            group.leave()
                        }
                    )
                }
            } else {
                if subscribedTopicsRWPublisher.value.contains(topic) {
                    group.enter()
                    subscribedTopicsRWPublisher.value.remove(topic)
                    Messaging.messaging().unsubscribe(
                        fromTopic: topic,
                        completion: { [weak self] error in
                            if error != nil {
                                errorTopics.insert(topic)
                                self?.subscribedTopicsRWPublisher.value.insert(topic)
                            }
                            group.leave()
                        }
                    )
                }

            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            if errorTopics.isEmpty {
                subject.send(())
                subject.send(completion: .finished)
            } else {
                subject.send(
                    completion: .failure(
                        .notAllTopicsChanged(
                            unchanged: errorTopics
                        )
                    )
                )
            }

            self.subscribingLoadingSubject.send(false)
        }
        return subject.eraseToAnyPublisher()
    }

}

fileprivate extension Defaults.Keys {
    static let subscribedTopics = Defaults.Key<[String]>("push_firebase_subscribed_topics", default: [])
    static let wasFirstTopicsSubscription = Defaults.Key<Bool>("push_firebase_wasFirstTopicsSubscription", default: false)
}
