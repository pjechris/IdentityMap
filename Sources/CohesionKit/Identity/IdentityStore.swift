import Foundation

/// Manages entities lifecycle and synchronisation
public class IdentityMap {
    public typealias Update<T> = (inout T) -> Void

    /// the queue on which identity map do its heavy work
    private let identityQueue = DispatchQueue(label: "com.cohesionkit.identitymap", attributes: .concurrent)
    private let logger: Logger?
    private let registry: ObserverRegistry

    private(set) var storage: EntitiesStorage = EntitiesStorage()
    private(set) var refAliases: AliasStorage = [:]
    private lazy var storeVisitor = IdentityMapStoreVisitor(identityMap: self)


    /// Create a new IdentityMap instance optionally with a queue and a logger
    /// - Parameter queue: the queue on which to receive updates. If not defined it default to main
    /// - Parameter logger: a logger to follow/debug identity internal state
    public init(queue: DispatchQueue = .main, logger: Logger? = nil) {
        self.logger = logger
        self.registry = ObserverRegistry(queue: queue)
    }

    /// Store an entity in the storage. Entity will be stored only if stamp (`modifiedAt`) is higher than in previous
    /// insertion.
    /// - Parameter entity: the element to store in the identity map
    /// - Parameter named: an alias to reference the entity and retrieve it using it
    /// - Parameter modifiedAt: if entity was already stored it will be used to determine if the  update should be  applied or discarded
    /// - Parameter ifPresent: applies the closure before storing it if it's already been stored. In this case this is similar as
    /// calling `update`
    /// - Returns: an object to observe changes on the entity
    public func store<T: Identifiable>(
        entity: T,
        named: AliasKey<T>? = nil,
        modifiedAt: Stamp? = nil,
        ifPresent update: Update<T>? = nil
    ) -> EntityObserver<T> {
        identityQueue.sync(flags: .barrier) {
            var entity = entity

            if storage[entity] != nil {
                update?(&entity)
            }

            let node = nodeStore(entity: entity, modifiedAt: modifiedAt)

            if let alias = named {
                refAliases.insert(node, key: alias)
                logger?.didRegisterAlias(alias)
            }

            self.registry.postNotifications()

            return EntityObserver(node: node, registry: registry)
        }
    }

    /// Store an aggregate in the storage. Each aggregate entities will be stored only if stamp (`modifiedAt`) is higher than in previous
    /// insertion. Finally aggregate will be stored accordingly to each of its entities.
    /// - Parameter entity: the aggregate to store in the identity map
    /// - Parameter named: an alias to reference the aggregate and retrieve it using it
    /// - Parameter modifiedAt: if aggregate was already stored it will be used to determine if the  update should be  applied or discarded
    /// - Parameter ifPresent: applies the closure before storing it if it's already been stored. In this case this is similar as
    /// calling `update`
    /// - Returns: an object to observe changes on the entity
    public func store<T: Aggregate>(
        entity: T,
        named: AliasKey<T>? = nil,
        modifiedAt: Stamp? = nil,
        ifPresent update: Update<T>? = nil
    ) -> EntityObserver<T> {
        identityQueue.sync(flags: .barrier) {
            var entity = entity

            if storage[entity] != nil {
                update?(&entity)
            }

            let node = nodeStore(entity: entity, modifiedAt: modifiedAt)

            if let alias = named {
                refAliases.insert(node, key: alias)
                logger?.didRegisterAlias(alias)
            }

            self.registry.postNotifications()

            return EntityObserver(node: node, registry: registry)
        }
    }

    /// Store multiple entities at once
    public func store<C: Collection>(entities: C, named: AliasKey<C>? = nil, modifiedAt: Stamp? = nil)
    -> [EntityObserver<C.Element>] where C.Element: Identifiable {
        identityQueue.sync(flags: .barrier) {
            let nodes = entities.map { nodeStore(entity: $0, modifiedAt: modifiedAt) }

            if let alias = named {
                refAliases.insert(nodes, key: alias)
                logger?.didRegisterAlias(alias)
            }

            self.registry.postNotifications()

            return nodes.map { EntityObserver(node: $0, registry: registry) }
        }
    }

    /// store multiple aggregates at once
    public func store<C: Collection>(entities: C, named: AliasKey<C>? = nil, modifiedAt: Stamp? = nil)
    -> [EntityObserver<C.Element>] where C.Element: Aggregate {
        identityQueue.sync(flags: .barrier) {
            let nodes = entities.map { nodeStore(entity: $0, modifiedAt: modifiedAt) }

            if let alias = named {
                refAliases.insert(nodes, key: alias)
                logger?.didRegisterAlias(alias)
            }

            self.registry.postNotifications()

            return nodes.map { EntityObserver(node: $0, registry: registry) }
        }
    }

    /// Try to find an entity/aggregate in the storage.
    /// - Returns: nil if not found, an `EntityObserver`` otherwise
    /// - Parameter type: the entity type
    /// - Parameter id: the entity id
    public func find<T: Identifiable>(_ type: T.Type, id: T.ID) -> EntityObserver<T>? {
        identityQueue.sync {
            if let node = storage[T.self, id: id] {
                return EntityObserver(node: node, registry: registry)
            }

            return nil
        }
    }

    /// Try to find an entity/aggregate registered under `named` alias
    /// - Parameter named: the alias to look for
    public func find<T: Identifiable>(named: AliasKey<T>) -> AliasObserver<T> {
        identityQueue.sync {
            AliasObserver(alias: refAliases[named], registry: registry)
        }
    }

    /// Try to find a collected registered under `named` alias
    /// - Returns: an observer returning the alias value. Note that the value will be an Array
    public func find<C: Collection>(named: AliasKey<C>) -> AliasObserver<[C.Element]> {
        identityQueue.sync {
            AliasObserver(alias: refAliases[named], registry: registry)
        }
    }

    func nodeStore<T: Identifiable>(entity: T, modifiedAt: Stamp?) -> EntityNode<T> {
        let node = storage[entity, new: EntityNode(entity, modifiedAt: nil) { [registry] in
            registry.postNotification(for: $0)
        }]

        do {
            try node.updateEntity(entity, modifiedAt: modifiedAt)
            logger?.didStore(T.self, id: entity.id)
        }
        catch {
            logger?.didFailedToStore(T.self, id: entity.id, error: error)
        }

        return node
    }

    func nodeStore<T: Aggregate>(entity: T, modifiedAt: Stamp?) -> EntityNode<T> {
        let node = storage[entity, new: EntityNode(entity, modifiedAt: nil) { [registry] in
            registry.postNotification(for: $0)
        }]

        // disable changes while doing the entity update
        node.applyChildrenChanges = false

        // clear all children to avoid a removed child to be kept as child
        node.removeAllChildren()

        for keyPathContainer in entity.nestedEntitiesKeyPaths {
            keyPathContainer.accept(node, entity, modifiedAt, storeVisitor)
        }

        node.applyChildrenChanges = true

        do {
            try node.updateEntity(entity, modifiedAt: modifiedAt)
            logger?.didStore(T.self, id: entity.id)
        }
        catch {
            logger?.didFailedToStore(T.self, id: entity.id, error: error)
        }

        return node
    }

}

// MARK: Update

extension IdentityMap {
    /// Updates an **already stored** entity using a closure. Useful to update a few properties or when you assume the entity
    /// should already be stored.
    /// Note: the closure is evaluated before checking `modifiedAt`. As such the closure execution does not mean
    /// the change was applied
    ///
    /// - Returns: true if entity exists and might be updated, false otherwise. The update might **not** be applied if modifiedAt is too old
    @discardableResult
    public func update<T: Identifiable>(_ type: T.Type, id: T.ID, modifiedAt: Stamp? = nil, update: Update<T>) -> Bool {
        identityQueue.sync(flags: .barrier) {
            guard var entity = storage[T.self, id: id]?.ref.value else {
                return false
            }

            update(&entity)

            _ = nodeStore(entity: entity, modifiedAt: modifiedAt)

            self.registry.postNotifications()

            return true
        }
    }

    /// Updates an **already stored** alias using a closure. This is useful if you don't have a full entity for update
    /// but just a few attributes/modifications.
    /// Note: the closure is evaluated before checking `modifiedAt`. As such the closure execution does not mean
    /// the change was applied
    ///
    /// - Returns: true if entity exists and might be updated, false otherwise. The update might **not** be applied if modifiedAt is too old
    @discardableResult
    public func update<T: Aggregate>(_ type: T.Type, id: T.ID, modifiedAt: Stamp? = nil, _ update: Update<T>) -> Bool {
        identityQueue.sync(flags: .barrier) {
            guard var entity = storage[T.self, id: id]?.ref.value else {
                return false
            }

            update(&entity)

            _ = nodeStore(entity: entity, modifiedAt: modifiedAt)

            self.registry.postNotifications()

            return true
        }
    }

    /// Updates an **already stored** alias using a closure.
    /// Note: the closure is evaluated before checking `modifiedAt`. As such the closure execution does not mean
    /// the change was applied
    /// - Returns: true if entity exists and might be updated, false otherwise. The update might **not** be applied if modifiedAt is too old
    @discardableResult
    public func update<T: Identifiable>(named: AliasKey<T>, modifiedAt: Stamp? = nil, update: Update<T>) -> Bool {
        identityQueue.sync(flags: .barrier) {
            guard let entity = refAliases[named].value else {
                return false
            }

            var value = entity.ref.value
            update(&value)
            let node = nodeStore(entity: value, modifiedAt: modifiedAt)

            // ref might have changed
            refAliases.insert(node, key: named)

            self.registry.postNotifications()

            return true
        }
    }

    /// Updates an **already stored** alias using a closure.
    /// Note: the closure is evaluated before checking `modifiedAt`. As such the closure execution does not mean
    /// the change was applied
    /// - Returns: true if entity exists and might be updated, false otherwise. The update might **not** be applied if modifiedAt is too old
    @discardableResult
    public func update<T: Aggregate>(named: AliasKey<T>, modifiedAt: Stamp? = nil, update: Update<T>) -> Bool {
        identityQueue.sync(flags: .barrier) {
            guard let entity = refAliases[named].value else {
                return false
            }

            var value = entity.ref.value
            update(&value)
            let node = nodeStore(entity: value, modifiedAt: modifiedAt)

            // ref might have changed
            refAliases.insert(node, key: named)

            self.registry.postNotifications()

            return true
        }
    }

    /// Updates an **already existing** collection alias content
    /// Note: the closure is evaluated before checking `modifiedAt`. As such the closure execution does not mean
    /// the change was applied
    /// - Returns: true if entity exists and might be updated, false otherwise. The update might **not** be applied if modifiedAt is too old
    @discardableResult
    public func update<C: Collection>(named: AliasKey<C>, modifiedAt: Stamp? = nil, update: Update<[C.Element]>)
    -> Bool where C.Element: Identifiable {
        identityQueue.sync(flags: .barrier) {
            guard let entities = refAliases[named].value else {
                return false
            }

            var values = entities.map(\.ref.value)
            update(&values)

            let nodes = values.map { nodeStore(entity: $0, modifiedAt: modifiedAt) }

            // update alias because `update` may have added/removed entities
            refAliases.insert(nodes, key: named)

            self.registry.postNotifications()

            return true
        }
    }

    /// Updates an **already existing** collection alias content
    ///  Note: the closure is evaluated before checking `modifiedAt`. As such the closure execution does not mean
    /// the change was applied
    /// - Returns: true if entity exists and might be updated, false otherwise. The update might **not** be applied if modifiedAt is too old
    @discardableResult
    public func update<C: Collection>(named: AliasKey<C>, modifiedAt: Stamp? = nil, update: Update<[C.Element]>)
    -> Bool where C.Element: Aggregate {
        identityQueue.sync(flags: .barrier) {
            guard let entities = refAliases[named].value else {
                return false
            }

            var values = entities.map(\.ref.value)
            update(&values)

            let nodes = values.map { nodeStore(entity: $0, modifiedAt: modifiedAt) }

            // update alias because `update` may have added/removed entities
            refAliases.insert(nodes, key: named)

            self.registry.postNotifications()

            return true
        }
    }
}

// MARK: Delete

extension IdentityMap {
    /// Removes an alias from the storage
    public func removeAlias<T>(named: AliasKey<T>) {
        refAliases.remove(for: named)
        logger?.didUnregisterAlias(named)
    }

    /// Removes an alias from the storage
    public func removeAlias<C: Collection>(named: AliasKey<C>) {
        refAliases.remove(for: named)
        logger?.didUnregisterAlias(named)
    }

    /// Removes all alias from identity map
    public func removeAllAlias() {
        refAliases.removeAll()
    }

    /// Removes all alias AND all objects stored weakly. You should not need this method and rather use `removeAlias`.
    /// But this can be useful if you fear retain cycles
    public func removeAll() {
        refAliases.removeAll()
        storage.removeAll()
    }
}