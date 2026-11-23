import SwiftUI

/// A small window into the playback order.
struct SlideshowJourneyList: View {
    let journeys: [EarthSlideshowSegment]
    let currentIndex: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let rowHeight: CGFloat = 68
    private let tickCenter: CGFloat = 16
    private let extensionLength: CGFloat = 32
    private let railColor = Color.white.opacity(0.36)

    private var visibleRange: Range<Int> {
        let start = min(max(0, currentIndex - 1), max(0, journeys.count - 3))
        return start..<min(start + 3, journeys.count)
    }

    var body: some View {
        let range = visibleRange
        VStack(alignment: .leading, spacing: 0) {
            ForEach(journeys[range]) { journey in
                row(journey, isCurrent: journey.id == journeys[currentIndex].id)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topLeading) {
            rail(for: range)
        }
        .shadow(color: .black.opacity(0.95), radius: 3, y: 1)
        .frame(maxWidth: 356, alignment: .leading)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: currentIndex)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("slideshow-journey-list")
    }

    private func rail(for range: Range<Int>) -> some View {
        Rectangle()
            .fill(railColor)
            .frame(width: 1, height: CGFloat(range.count - 1) * rowHeight)
            .accessibilityHidden(true)
            .overlay(alignment: .top) {
                if range.lowerBound > 0 {
                    continuation(above: true)
                        .offset(y: -extensionLength)
                }
            }
            .overlay(alignment: .bottom) {
                if range.upperBound < journeys.count {
                    continuation(above: false)
                        .offset(y: extensionLength)
                }
            }
            .offset(y: tickCenter)
    }

    private func row(_ journey: EarthSlideshowSegment, isCurrent: Bool) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Capsule()
                .fill(.white)
                .frame(width: 20, height: 1.5)
                .scaleEffect(x: isCurrent ? 1 : 0.42, y: 1, anchor: .leading)
                .opacity(isCurrent ? 1 : 0.48)
                .padding(.top, tickCenter - 0.75)
                .accessibilityHidden(true)
            caption(journey, isCurrent: isCurrent)
        }
        .frame(height: rowHeight, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier(isCurrent ? "slideshow-current-journey" : "slideshow-queued-journey")
    }

    private func caption(_ journey: EarthSlideshowSegment, isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(routeName(for: journey))
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Color(white: isCurrent ? 1 : 0.72))
                .lineLimit(1)
            Text(AppLocalization.dateRange(from: journey.startDate, to: journey.endDate))
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(Color(white: isCurrent ? 0.88 : 0.66))
                .lineLimit(1)
        }
        .scaleEffect(isCurrent ? 1 : 0.92, anchor: .leading)
    }

    private func continuation(above: Bool) -> some View {
        LinearGradient(
            colors: [railColor, .clear],
            startPoint: above ? .bottom : .top,
            endPoint: above ? .top : .bottom
        )
            .frame(width: 1, height: extensionLength)
            .transition(.opacity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                above
                    ? AppLocalization.string("slideshow.hidden_previous_journeys", defaultValue: "More previous trips")
                    : AppLocalization.string("slideshow.hidden_upcoming_journeys", defaultValue: "More upcoming trips")
            )
            .accessibilityIdentifier(above ? "slideshow-journey-more-above" : "slideshow-journey-more-below")
            .accessibilitySortPriority(above ? 1 : -1)
    }

    private func routeName(for journey: EarthSlideshowSegment) -> String {
        let labels = journey.visits.lazy.map { PlaceDisplayLabel(place: $0) }
        guard let first = labels.first else { return AppLocalization.unresolvedPlace }
        let start = first.displayCity
        guard let end = labels.last(where: { $0.hasCity && $0.displayCity != start }) else { return start }
        return "\(start) › \(end.displayCity)"
    }
}
