/*
 This source file is part of the Swift.org open source project
 
 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception
 
 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Basic
import PackageModel
import PackageLoading
import Utility

// FIXME: This doesn't belong here.
import func POSIX.exit

enum PackageGraphError: Swift.Error {
    /// Indicates a non-root package with no modules.
    case noModules(Package)

    /// The package dependency declaration has cycle in it.
    case cycleDetected((path: [Manifest], cycle: [Manifest]))

    /// The product dependency not found.
    case productDependencyNotFound(name: String, package: String?)

    /// The product dependency was found but the package name did not match.
    case productDependencyIncorrectPackage(name: String, package: String)
}

extension PackageGraphError: FixableError {
    var error: String {
        switch self {
        case .noModules(let package):
            return "the package \(package) contains no modules"

        case .cycleDetected(let cycle):
            return "found cyclic dependency declaration: " +
                (cycle.path + cycle.cycle).map{$0.name}.joined(separator: " -> ") +
                " -> " + cycle.cycle[0].name

        case .productDependencyNotFound(let name, _):
            return "The product dependency '\(name)' was not found."

        case .productDependencyIncorrectPackage(let name, let package):
            return "The product dependency '\(name)' on package '\(package)' was not found."
        }
    }

    var fix: String? {
        switch self {
        case .noModules:
            return "create at least one module"
        case .cycleDetected, .productDependencyNotFound, .productDependencyIncorrectPackage:
            return nil
        }
    }
}

/// A helper class for loading a package graph.
public struct PackageGraphLoader {
    /// Create a package loader.
    public init() { }

    /// Load the package graph for the given package path.
    public func load(rootManifests: [Manifest], externalManifests: [Manifest], fileSystem: FileSystem = localFileSystem) throws -> PackageGraph {
        let rootManifestSet = Set(rootManifests)
        // Manifest url to manifest map.
        let manifestURLMap: [String: Manifest] = Dictionary(items: (externalManifests + rootManifests).map { ($0.url, $0) })
        // Detect cycles in manifest dependencies.
        if let cycle = findCycle(rootManifests, successors: { $0.package.dependencies.map{ manifestURLMap[$0.url]! } }) {
            throw PackageGraphError.cycleDetected(cycle)
        }
        // Sort all manifests toplogically.
        let allManifests = try! topologicalSort(rootManifests) { $0.package.dependencies.map{ manifestURLMap[$0.url]! } }

        // Create the packages and convert to modules.
        var manifestToPackage: [Manifest: Package] = [:]
        for manifest in allManifests {
            let isRootPackage = rootManifestSet.contains(manifest)

            // Derive the path to the package.
            //
            // FIXME: Lift this out of the manifest.
            let packagePath = manifest.path.parentDirectory

            // Create a package from the manifest and sources.
            let builder = PackageBuilder(
                manifest: manifest, path: packagePath, fileSystem: fileSystem, createImplicitProduct: !isRootPackage)
            let package = try builder.construct()
            manifestToPackage[manifest] = package
            
            // Throw if any of the non-root package is empty.
            if package.modules.isEmpty && !isRootPackage {
                throw PackageGraphError.noModules(package)
            }
        }
        // Resolve dependencies and create resolved packages.
        let resolvedPackages = try createResolvedPackages(allManifests: allManifests, manifestToPackage: manifestToPackage)
        // Filter out the root packages.
        let resolvedRootPackages = resolvedPackages.filter{ rootManifestSet.contains($0.manifest) }
        return PackageGraph(rootPackages: resolvedRootPackages)
    }
}

/// Create resolved packages from the loaded packages.
private func createResolvedPackages(allManifests: [Manifest], manifestToPackage: [Manifest: Package]) throws -> [ResolvedPackage] {
    var packageURLMap: [String: ResolvedPackage] = [:]
    // Resolve each package in reverse topological order of their manifest.
    return try allManifests.lazy.reversed().map { manifest in
        let package = manifestToPackage[manifest]!

        // Get all the external dependencies of this package.
        let dependencies = manifest.package.dependencies.map{ packageURLMap[$0.url]! }

        // Topologically Sort all the local modules in this package.
        let modules = try! topologicalSort(package.modules, successors: { $0.dependencies })

        // Make sure these module names are unique in the graph.
        let dependencyModuleNames = dependencies.lazy.flatMap{ $0.modules }.flatMap{ $0.name }
        if let duplicateModules = dependencyModuleNames.duplicates(modules.lazy.map{$0.name}) {
            throw ModuleError.duplicateModule(duplicateModules.first!)
        }

        // Add system module dependencies directly to the target's dependencies because they are 
        // not representable as a product.
        let systemModulesDependencies = dependencies.flatMap{ $0.modules }
            .filter{ $0.type == .systemModule }.map(ResolvedModule.Dependency.target)

        let allProducts = dependencies.flatMap{ $0.products }.filter{ $0.type != .test }
        let allProductsMap = Dictionary(items: allProducts.map{($0.name, $0)})

        // Resolve the modules.
        var moduleToResolved = [Module: ResolvedModule]()
        let resolvedModules: [ResolvedModule] = try modules.lazy.reversed().map { module in

            // Get the product dependencies for targets in this package.
            let productDependencies: [ResolvedProduct]
            switch manifest.package {
            case .v3:
                productDependencies = allProducts
            case .v4:
                productDependencies = try module.productDependencies.map{ 
                    // Find the product in this package's dependency products.
                    guard let product = allProductsMap[$0.name] else {
                        throw PackageGraphError.productDependencyNotFound(name: $0.name, package: $0.package)
                    }
                    // If package name is mentioned, ensure it is valid.
                    if let packageName = $0.package {
                        // Find the declared package and check that it contains the product we found above.
                        guard let package = dependencies.first(where: { $0.name == packageName }),
                              package.products.contains(product) else {
                            throw PackageGraphError.productDependencyIncorrectPackage(
                                name: $0.name, package: packageName)
                        }
                    }
                    return product
                }
            }

            let moduleDependencies = module.dependencies.map{ moduleToResolved[$0]! }.map(ResolvedModule.Dependency.target)
            let resolvedModule = ResolvedModule(
                module: module,
                dependencies: moduleDependencies + systemModulesDependencies + productDependencies.map(ResolvedModule.Dependency.product)
            )
            moduleToResolved[module] = resolvedModule 
            return resolvedModule
        }

        // Create resolved products.
        let resolvedProducts = package.products.map { product in
            return ResolvedProduct(product: product, modules: product.modules.map{ moduleToResolved[$0]! })
        }
        // Create resolved package.
        let resolvedPackage = ResolvedPackage(
            package: package, dependencies: dependencies, modules: resolvedModules, products: resolvedProducts)
        packageURLMap[package.manifest.url] = resolvedPackage 
        return resolvedPackage 
    }
}

// FIXME: Possibly lift this to Basic.
private extension Sequence where Iterator.Element: Hashable {
    // Returns the set of duplicate elements in two arrays, if any.
    func duplicates(_ other: Array<Iterator.Element>) -> Set<Iterator.Element>? {
        let dupes = Set(self).intersection(Set(other))
        return dupes.isEmpty ? nil : dupes
    }
}
