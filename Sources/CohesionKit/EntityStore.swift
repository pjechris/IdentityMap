import Foundation

@available(*, deprecated, renamed: "EntityStore")
public typealias IdentityMap = EntityStore

/// Manages entities lifecycle and synchronisation
public class EntityStore {
    public typealias Update<T> = (inout T) -> Void

    /// the queue on which identity map do its heavy work
    private let identityQueue = DispatchQueue(label: "com.cohesionkit.identitymap", attributes: .concurrent)
    private let logger: Logger?
    private let registry: ObserverRegistry

    private(set) var indexer: EntityIndexer = [:]
    private(set) var storage: EntitiesStorage = EntitiesStorage()
    private(set) var refAliases: AliasStorage = [:]
    private lazy var storeVisitor = EntityStoreStoreVisitor(entityStore: self)

    /// Create a new EntityStore instance optionally with a queue and a logger
    /// - Parameter queue: the queue on which to receive updates. If nil identitymap will create its own.
    /// - Parameter logger: a logger to follow/debug identity internal state
    public convenience init(queue: DispatchQueue? = nil, logger: Logger? = nil) {
        self.init(registry: ObserverRegistry(queue: queue), logger: logger)
    }

    init(registry: ObserverRegistry, logger: Logger? = nil) {
        self.logger = logger
        self.registry = registry
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
        transaction {
            var entity = entity
            let entityKey = ObjectKey(of: T.self, id: entity.id)

            if storage[entity] != nil {
                update?(&entity)
            }

            let node = nodeStore(entity: entity, modifiedAt: modifiedAt)

            if let key = named {
                storeAlias(content: entity, key: key, modifiedAt: modifiedAt)
            }

            store(entity, identifier: entityKey, modifiedAt: modifiedAt)

            return EntityObserver(entity: entity, key: entityKey, registry: registry)
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
        transaction {
            var entity = entity

            if storage[entity] != nil {
                update?(&entity)
            }

            if let key = named {
                storeAlias(content: entity, key: key, modifiedAt: modifiedAt)
            }

            let node = nodeStore(entity: entity, modifiedAt: modifiedAt)

            return EntityObserver(node: node, registry: registry)
        }
    }

    /// Store multiple entities at once
    public func store<C: Collection>(entities: C, named: AliasKey<C>? = nil, modifiedAt: Stamp? = nil)
    -> EntityObserver<[C.Element]> where C.Element: Identifiable {
        transaction {
            if let key = named {
                storeAlias(content: entities, key: key, modifiedAt: modifiedAt)
            }

            let nodes = entities.map { nodeStore(entity: $0, modifiedAt: modifiedAt) }

            return EntityObserver(nodes: nodes, registry: registry)
        }
    }

    /// store multiple aggregates at once
    public func store<C: Collection>(entities: C, named: AliasKey<C>? = nil, modifiedAt: Stamp? = nil)
    -> EntityObserver<[C.Element]> where C.Element: Aggregate {
        transaction {
            if let key = named {
                storeAlias(content: entities, key: key, modifiedAt: modifiedAt)
            }

            let nodes = entities.map { nodeStore(entity: $0, modifiedAt: modifiedAt) }


            return EntityObserver(nodes: nodes, registry: registry)
        }
    }

    /// Try to find an entity/aggregate in the storage.
    /// - Returns: nil if not found, an `EntityObserver`` otherwise
    /// - Parameter type: the entity type
    /// - Parameter id: the entity id
    public func find<T: Identifiable>(_ type: T.Type, id: T.ID) -> EntityObserver<T>? {
        identityQueue.sync {
            let key = ObjectKey(of: T.self, id: id)

            if let entity = indexer[key]?.entity as? T {
                return EntityObserver(entity: entity, key: key, registry: registry)
            }

            if let node = storage[T.self, id: id] {
                return EntityObserver(node: node, registry: registry)
            }

            return nil
        }
    }

    /// Try to find an entity/aggregate registered under `named` alias
    /// - Parameter named: the alias to look for
    public func find<T: Identifiable>(named: AliasKey<T>) -> EntityObserver<T?> {
        identityQueue.sync {
            let node = refAliases[safe: named, onChange: registry.enqueueChange(for:)]
            return EntityObserver(alias: node, registry: registry)
        }
    }

    /// Try to find a collected registered under `named` alias
    /// - Returns: an observer returning the alias value. Note that the value will be an Array
    public func find<C: Collection>(named: AliasKey<C>) -> EntityObserver<C?> {
        identityQueue.sync {
            let node = refAliases[safe: named, onChange: registry.enqueueChange(for:)]
            return EntityObserver(alias: node, registry: registry)
        }
    }

    func nodeStore<T: Identifiable>(in node: EntityNode<T>? = nil, entity: T, modifiedAt: Stamp?) -> EntityNode<T> {
        let node = node ?? storage[entity, new: EntityNode(entity, modifiedAt: nil) { [registry] in
            registry.enqueueChange(for: $0)
        }]

        guard !registry.hasPendingChange(for: node) else {
            return node
        }

        do {
            try node.updateEntity(entity, modifiedAt: modifiedAt)
            logger?.didStore(T.self, id: entity.id)
        }
        catch {
            logger?.didFailedToStore(T.self, id: entity.id, error: error)
        }

        return node
    }

    func nodeStore<T: Aggregate>(in node: EntityNode<T>? = nil, entity: T, modifiedAt: Stamp?) -> EntityNode<T> {
        let node = node ?? storage[entity, new: EntityNode(entity, modifiedAt: nil) { [registry] in
            registry.enqueueChange(for: $0)
        }]

        guard !registry.hasPendingChange(for: node) else {
            return node
        }

        // clear all children to avoid a removed child to be kept as child
        node.removeAllChildren()

        node.applyChildrenChanges = false
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

    func store<E: Identifiable>(_ entity: E, identifier: ObjectKey, modifiedAt: Stamp?) {
        var metadata = indexer[identifier]?.metadata ?? EntityMetadata()

        guard !registry.hasPendingChange(for: identifier) else {
            return
        }

        if let modifiedAt, indexer[identifier]?.modifiedAt ?? 0 >= modifiedAt {
            return
        }

        if let aggregate = entity as? any Aggregate {
            let refs = storeChildren(of: aggregate, modifiedAt: modifiedAt)

            let addedRefs = refs.subtracting(metadata.childrenRefs)
            let removedRefs = metadata.childrenRefs.subtracting(refs)

            for added in addedRefs {
                indexer[added]?.metadata.parents.insert(identifier)
            }

            for removed in removedRefs {
                let isRemoved = indexer[removed]?.metadata.parents.remove(identifier)
                assert(isRemoved != nil)

                if indexer[removed]?.metadata.parents.isEmpty ?? false {
                    // TODO
                }
            }

            metadata.childrenRefs = refs
        }

        let indexed = IndexedEntity(entity: entity, modifiedAt: modifiedAt, metadata: metadata)

        indexer[identifier] = indexed

        registry.enqueueChange(for: indexed, key: identifier)
    }

    private func storeChildren(of entity: some Aggregate, modifiedAt: Stamp?) -> Set<ObjectKey> {
        var refs: Set<ObjectKey> = []

        for keyPathContainer in entity.nestedEntitiesKeyPaths {
            refs = refs.union(keyPathContainer.store(entity, modifiedAt, self))
        }

        return refs
    }

    private func storeAlias<T>(content: T?, key: AliasKey<T>, modifiedAt: Stamp?) {
        let aliasNode = refAliases[safe: key, onChange: registry.enqueueChange(for:)]
        let aliasContainer = AliasContainer(key: key, content: content)

        _ = nodeStore(in: aliasNode, entity: aliasContainer, modifiedAt: modifiedAt)

        logger?.didRegisterAlias(key)
    }

    private func transaction<T>(_ body: () -> T) -> T {
        identityQueue.sync(flags: .barrier) {
            let returnValue = body()

            self.registry.postChanges()

            return returnValue
        }
    }
}

// MARK: Update

extension EntityStore {
    /// Updates an **already stored** entity using a closure. Useful to update a few properties or when you assume the entity
    /// should already be stored.
    /// Note: the closure is evaluated before checking `modifiedAt`. As such the closure execution does not mean
    /// the change was applied
    ///
    /// - Returns: true if entity exists and might be updated, false otherwise. The update might **not** be applied if modifiedAt is too old
    @discardableResult
    public func update<T: Identifiable>(_ type: T.Type, id: T.ID, modifiedAt: Stamp? = nil, update: Update<T>) -> Bool {
        transaction {
            guard var entity = storage[T.self, id: id]?.ref.value else {
                return false
            }

            update(&entity)

            _ = nodeStore(entity: entity, modifiedAt: modifiedAt)

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
        transaction {
            guard var entity = storage[T.self, id: id]?.ref.value else {
                return false
            }

            update(&entity)

            _ = nodeStore(entity: entity, modifiedAt: modifiedAt)

            return true
        }
    }

    /// Updates an **already stored** alias using a closure.
    /// Note: the closure is evaluated before checking `modifiedAt`. As such the closure execution does not mean
    /// the change was applied
    /// - Returns: true if entity exists and might be updated, false otherwise. The update might **not** be applied if modifiedAt is too old
    @discardableResult
    public func update<T: Identifiable>(named: AliasKey<T>, modifiedAt: Stamp? = nil, update: Update<T>) -> Bool {
        transaction {
            guard let aliasNode = refAliases[named], var content = aliasNode.ref.value.content else {
                return false
            }

            update(&content)

            storeAlias(content: content, key: named, modifiedAt: modifiedAt)

            return true
        }
    }

    /// Updates an **already stored** alias using a closure.
    /// Note: the closure is evaluated before checking `modifiedAt`. As such the closure execution does not mean
    /// the change was applied
    /// - Returns: true if entity exists and might be updated, false otherwise. The update might **not** be applied if modifiedAt is too old
    @discardableResult
    public func update<T: Aggregate>(named: AliasKey<T>, modifiedAt: Stamp? = nil, update: Update<T>) -> Bool {
        transaction {
            guard let aliasNode = refAliases[named], var content = aliasNode.ref.value.content else {
                return false
            }

            update(&content)

            storeAlias(content: content, key: named, modifiedAt: modifiedAt)

            return true
        }
    }

    /// Updates an **already existing** collection alias content
    /// Note: the closure is evaluated before checking `modifiedAt`. As such the closure execution does not mean
    /// the change was applied
    /// - Returns: true if entity exists and might be updated, false otherwise. The update might **not** be applied if modifiedAt is too old
    @discardableResult
    public func update<C: Collection>(named: AliasKey<C>, modifiedAt: Stamp? = nil, update: Update<C>)
    -> Bool where C.Element: Identifiable {
        transaction {
            guard let aliasNode = refAliases[named], var content = aliasNode.ref.value.content else {
                return false
            }

            update(&content)

            storeAlias(content: content, key: named, modifiedAt: modifiedAt)

            return true
        }
    }

    /// Updates an **already existing** collection alias content
    ///  Note: the closure is evaluated before checking `modifiedAt`. As such the closure execution does not mean
    /// the change was applied
    /// - Returns: true if entity exists and might be updated, false otherwise. The update might **not** be applied if modifiedAt is too old
    @discardableResult
    public func update<C: Collection>(named: AliasKey<C>, modifiedAt: Stamp? = nil, update: Update<C>)
    -> Bool where C.Element: Aggregate {
        transaction {
            guard let aliasNode = refAliases[named], var content = aliasNode.ref.value.content else {
                return false
            }

            update(&content)

            storeAlias(content: content, key: named, modifiedAt: modifiedAt)

            return true
        }
    }
}

// MARK: Delete

extension EntityStore {
    /// Removes an alias from the storage
    public func removeAlias<T>(named: AliasKey<T>) {
        transaction {
            if refAliases[named] != nil {
                storeAlias(content: nil, key: named, modifiedAt: nil)
                logger?.didUnregisterAlias(named)
            }
        }
    }

    /// Removes an alias from the storage
    public func removeAlias<C: Collection>(named: AliasKey<C>) {
        transaction {
            if refAliases[named] != nil {
                storeAlias(content: nil, key: named, modifiedAt: nil)
                logger?.didUnregisterAlias(named)
            }
        }

    }

    /// Removes all alias from identity map
    public func removeAllAlias() {
        transaction {
            removeAliases()
        }
    }

    /// Removes all alias AND all objects stored weakly. You should not need this method and rather use `removeAlias`.
    /// But this can be useful if you fear retain cycles
    public func removeAll() {
        transaction {
            removeAliases()
            storage.removeAll()
        }
    }

    private func removeAliases() {
        for (_, node) in refAliases {
                node.nullify()
        }
    }
}
