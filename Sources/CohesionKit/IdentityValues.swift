
import Foundation

/// Store values from an object inside a Dictionary which is queryable using `KeyPath`
@dynamicMemberLookup
public struct IdentityValues<Root> {
    let values: [AnyKeyPath: Any]

    public subscript<T: IdentityGraph>(dynamicMember keyPath: KeyPath<Root, T>) -> T {
        get { values[keyPath] as! T }
    }

    public subscript<T: IdentityGraph>(dynamicMember keyPath: KeyPath<Root, [T]>) -> [T] {
        get { values[keyPath] as! [T] }
    }

    public subscript<T: Identifiable>(dynamicMember keyPath: KeyPath<Root, T>) -> T {
        get { values[keyPath] as! T }
    }

    public subscript<T: Identifiable>(dynamicMember keyPath: KeyPath<Root, [T]>) -> [T] {
        get { values[keyPath] as! [T] }
    }


}
