import FirebaseMessaging
import Firebase
import PizzaKit
import Combine
import Defaults

// TODO: переписать на параллельные подписки (сейчас последовательные)
// TODO: возможно менять состояние топиков перед подпиской, а потом если ошибка, актуализировать
// -> так мы на UI сможем реагировать правильно
public class PizzaFirebasePushNotificationTopicsManager {

    // MARK: - Nested Types

    public enum ManagerError: Error {
        case notAllTopicsChanged
    }

    // MARK: - Properties

    public let allTopics: Set<String>
    public var subscribedTopics: Set<String> {
        subscribedTopicsSubject.value
    }
    public var subscribedTopicsPublisher: AnyPublisher<Set<String>, Never> {
        subscribedTopicsSubject.eraseToAnyPublisher()
    }
    public var subscribingLoadingPublisher: AnyPublisher<Bool, Never> {
        subscribingLoadingSubject.eraseToAnyPublisher()
    }
    private let subscribedTopicsSubject: CurrentValueSubject<Set<String>, Never>
    private let subscribingLoadingSubject: CurrentValueSubject<Bool, Never> = .init(false)

    private var bag = Set<AnyCancellable>()

    // MARK: - Initialization

    public init(allTopics: [String]) {
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

        NotificationCenter.default
            .publisher(for: .pushTokenUpdated)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] output in
                guard let self else { return }
                if !Defaults[.wasFirstTopicsSubscription] {
                    self.subscribeAllPublisher()
                        .sink(
                            receiveCompletion: { _ in },
                            receiveValue: { _ in
                                Defaults[.wasFirstTopicsSubscription] = true
                            }
                        )
                        .store(in: &self.bag)
                }
            }
            .store(in: &bag)
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

    public func subscribeAllPublisher() -> AnyPublisher<Void, ManagerError> {
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

    public func unsubscribeAllPublisher() -> AnyPublisher<Void, ManagerError> {
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

    public func subscribePublisher(to topic: String) -> AnyPublisher<Void, ManagerError> {
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

    public func unsubscribePublisher(from topic: String) -> AnyPublisher<Void, ManagerError> {
        handle(
            targetTopics: Set([topic]),
            isSubscription: false
        )
    }

    // MARK: - Private Methods

    private func handle(
        targetTopics: Set<String>,
        isSubscription: Bool
    ) -> AnyPublisher<Void, ManagerError> {
        let subject = PassthroughSubject<Void, ManagerError>()
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
