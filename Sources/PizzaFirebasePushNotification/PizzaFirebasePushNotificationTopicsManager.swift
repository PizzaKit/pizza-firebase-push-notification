import FirebaseMessaging
import Firebase
import PizzaKit
import Combine
import Defaults

public enum PizzaFirebasePushNotificationTopicsManagerError: Error {
    case notAllTopicsChanged
}

public typealias PizzaFirebasePushNotificationTopicsManagerPublisher = AnyPublisher<
    Void,
    PizzaFirebasePushNotificationTopicsManagerError
>

public protocol PizzaFirebasePushNotificationTopicsManager {
    init(allTopics: [String])

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

    func unsubscribe(from topic: String)
    func unsubscribePublisher(from topic: String) -> PizzaFirebasePushNotificationTopicsManagerPublisher
}

// TODO: переписать на параллельные подписки (сейчас последовательные)
// TODO: возможно менять состояние топиков перед подпиской, а потом если ошибка, актуализировать
// -> так мы на UI сможем реагировать правильно
public class PizzaFirebasePushNotificationTopicsManagerImpl: PizzaFirebasePushNotificationTopicsManager {

    // MARK: - Properties

    public let allTopics: Set<String>
    public var subscribedTopics: Set<String> {
        subscribedTopicsSubject.value
    }
    public var subscribedTopicsPublisher: PizzaRPublisher<Set<String>, Never> {
        PizzaCurrentValueRPublisher(subject: subscribedTopicsSubject)
    }
    public var subscribingLoadingPublisher: PizzaRPublisher<Bool, Never> {
        PizzaCurrentValueRPublisher(subject: subscribingLoadingSubject)
    }
    private let subscribedTopicsSubject: CurrentValueSubject<Set<String>, Never>
    private let subscribingLoadingSubject: CurrentValueSubject<Bool, Never> = .init(false)

    private var bag = Set<AnyCancellable>()

    // MARK: - Initialization

    public required init(allTopics: [String]) {
        self.allTopics = Set(allTopics)
        self.subscribedTopicsSubject = .init(Set(Defaults[.subscribedTopics]))

        self.subscribedTopicsSubject
            .receive(on: DispatchQueue.main)
            .sink { newTopics in
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
            .store(in: &bag)
        
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
            targetTopics: allTopics,
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
            targetTopics: allTopics,
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
        if !Defaults[.wasFirstTopicsSubscription] {
            subscribeAllPublisher()
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
        let subject = PassthroughSubject<Void, PizzaFirebasePushNotificationTopicsManagerError>()
        subscribingLoadingSubject.send(true)
        let group = DispatchGroup()

        var startTopics: Set<String> = {
            if isSubscription {
                return []
            }
            return targetTopics
        }()
        let endTopics: Set<String> = {
            if isSubscription {
                return targetTopics
            }
            return []
        }()
        allTopics.forEach { topic in
            group.enter()

            if isSubscription {
                Messaging.messaging().subscribe(
                    toTopic: topic,
                    completion: { error in
                        startTopics.insert(topic)
                        group.leave()
                    }
                )
            } else {
                Messaging.messaging().unsubscribe(
                    fromTopic: topic,
                    completion: { error in
                        startTopics.remove(topic)
                        group.leave()
                    }
                )
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.subscribedTopicsSubject.send(startTopics)
            if startTopics == endTopics {
                subject.send(())
                subject.send(completion: .finished)
            } else {
                subject.send(completion: .failure(.notAllTopicsChanged))
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
