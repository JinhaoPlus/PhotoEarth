import RealityKit
import simd
import SwiftUI
import UIKit

struct EarthRealityView: View {
    let places: [TravelPlace]
    let selectedPlaceID: String?

    var body: some View {
        RealityView { content in
            content.camera = .virtual

            let camera = PerspectiveCamera()
            camera.name = "photo-earth-camera"
            camera.position = SIMD3<Float>(0, 0, 4.35)
            camera.look(at: .zero, from: camera.position, relativeTo: nil)
            content.add(camera)
            content.cameraTarget = camera

            let earthRoot = Entity()
            earthRoot.name = rootName
            earthRoot.orientation = focusRotation(for: selectedPlaceID)
            content.add(earthRoot)

            let earthMesh = MeshResource.generateSphere(radius: GlobeMath.earthRadius)
            var earthMaterial = UnlitMaterial(
                color: UIColor(red: 0.015, green: 0.15, blue: 0.31, alpha: 1)
            )
            if let texture = try? await TextureResource(named: "BlueMarble") {
                earthMaterial.color = .init(
                    tint: UIColor.white,
                    texture: .init(texture)
                )
            }
            let earth = ModelEntity(mesh: earthMesh, materials: [earthMaterial])
            earth.name = "earth"
            earthRoot.addChild(earth)

            let routes = Entity()
            routes.name = "travel-routes"
            for pair in zip(places, places.dropFirst()) {
                addRoute(from: pair.0.coordinate, to: pair.1.coordinate, to: routes)
            }
            earthRoot.addChild(routes)

            for place in places {
                earthRoot.addChild(marker(for: place, selected: place.id == selectedPlaceID))
            }

            let moon = ModelEntity(
                mesh: .generateSphere(radius: 0.15),
                materials: [SimpleMaterial(color: UIColor(white: 0.58, alpha: 1), isMetallic: false)]
            )
            moon.position = SIMD3<Float>(2.23, 1.16, -0.4)
            content.add(moon)

            let keyLight = DirectionalLight()
            keyLight.light.intensity = 18_000
            keyLight.position = SIMD3<Float>(-3, 4, 5)
            keyLight.look(at: .zero, from: keyLight.position, relativeTo: nil)
            content.add(keyLight)

            let rimLight = PointLight()
            rimLight.light.intensity = 7_000
            rimLight.light.attenuationRadius = 12
            rimLight.position = SIMD3<Float>(3.5, 0.5, 2)
            content.add(rimLight)
        } update: { content in
            guard let root = content.entities.first(where: { $0.name.hasPrefix("earth-root|") }) else { return }
            let needsMove = root.name != rootName

            for place in places {
                guard let marker = root.findEntity(named: "marker-\(place.id)") as? ModelEntity else { continue }
                let selected = place.id == selectedPlaceID
                marker.scale = SIMD3<Float>(repeating: selected ? 1.35 : 1)
                marker.model?.materials = [Self.markerMaterial(selected: selected)]
                if let halo = marker.findEntity(named: "halo") as? ModelEntity {
                    halo.model?.materials = [Self.haloMaterial(selected: selected)]
                }
            }

            if needsMove {
                root.name = rootName
                root.move(
                    to: Transform(
                        scale: .one,
                        rotation: focusRotation(for: selectedPlaceID),
                        translation: .zero
                    ),
                    relativeTo: nil,
                    duration: 1.25,
                    timingFunction: .easeInOut
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var rootName: String { "earth-root|\(selectedPlaceID ?? "none")" }

    private func marker(for place: TravelPlace, selected: Bool) -> ModelEntity {
        let marker = ModelEntity(
            mesh: .generateSphere(radius: 0.042),
            materials: [Self.markerMaterial(selected: selected)]
        )
        marker.name = "marker-\(place.id)"
        marker.position = projectedPosition(
            coordinate: place.coordinate,
            radius: GlobeMath.earthRadius + 0.06
        )
        marker.scale = SIMD3<Float>(repeating: selected ? 1.35 : 1)

        let normal = simd_normalize(marker.position)
        let halo = ModelEntity(
            mesh: .generateCylinder(height: 0.006, radius: 0.06),
            materials: [Self.haloMaterial(selected: selected)]
        )
        halo.name = "halo"
        halo.position = normal * 0.012
        halo.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: normal)
        marker.addChild(halo)
        return marker
    }

    private func addRoute(from start: GeoCoordinate, to end: GeoCoordinate, to parent: Entity) {
        let startVector = simd_normalize(projectedPosition(coordinate: start, radius: 1))
        let endVector = simd_normalize(projectedPosition(coordinate: end, radius: 1))
        let material = SimpleMaterial(
            color: UIColor(red: 0.4, green: 0.9, blue: 1, alpha: 0.72),
            isMetallic: true
        )

        for step in 1..<28 {
            let progress = Float(step) / 28
            let direction = sphericalInterpolate(from: startVector, to: endVector, progress: progress)
            let altitude = sin(.pi * progress) * 0.14
            let dot = ModelEntity(mesh: .generateSphere(radius: 0.009), materials: [material])
            dot.position = direction * (GlobeMath.earthRadius + 0.045 + altitude)
            parent.addChild(dot)
        }
    }

    private func sphericalInterpolate(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        progress: Float
    ) -> SIMD3<Float> {
        let cosine = max(-1, min(1, simd_dot(start, end)))
        let angle = acos(cosine)
        guard angle > 0.0001 else { return start }
        let denominator = sin(angle)
        return simd_normalize(
            start * (sin((1 - progress) * angle) / denominator)
                + end * (sin(progress * angle) / denominator)
        )
    }

    private func focusRotation(for id: String?) -> simd_quatf {
        guard let place = places.first(where: { $0.id == id }) else { return simd_quatf() }
        let direction = simd_normalize(projectedPosition(coordinate: place.coordinate, radius: 1))
        let centerDirection = simd_normalize(SIMD3<Float>(-0.38, 0.08, 1))
        return simd_quatf(from: direction, to: centerDirection)
    }

    private func projectedPosition(coordinate: GeoCoordinate, radius: Float) -> SIMD3<Float> {
        var longitude = coordinate.longitude - 90
        if longitude < -180 { longitude += 360 }
        return GlobeMath.cartesian(
            coordinate: GeoCoordinate(latitude: coordinate.latitude, longitude: longitude),
            radius: radius
        )
    }

    private static func markerMaterial(selected: Bool) -> SimpleMaterial {
        SimpleMaterial(
            color: selected
                ? UIColor(red: 1, green: 0.72, blue: 0.18, alpha: 1)
                : UIColor(red: 0.32, green: 0.9, blue: 1, alpha: 0.95),
            isMetallic: true
        )
    }

    private static func haloMaterial(selected: Bool) -> SimpleMaterial {
        SimpleMaterial(
            color: selected
                ? UIColor(red: 1, green: 0.65, blue: 0.1, alpha: 0.42)
                : UIColor(red: 0.2, green: 0.82, blue: 1, alpha: 0.2),
            isMetallic: false
        )
    }
}
