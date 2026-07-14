//
//  ParkingLiveActivity.swift — target WITPWidgets
//  La sosta nella Dynamic Island e sulla Lock Screen.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct ParkingLiveActivity: Widget {

    private let blue = Color(red: 0.04, green: 0.52, blue: 1.00)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ParkingActivityAttributes.self) { context in
            // Lock Screen / banner
            HStack(spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.streetName)
                        .font(.headline).lineLimit(1)
                    Text(context.attributes.zoneLabel)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                timer(context)
                    .font(.title2.weight(.bold).monospacedDigit())
                    .foregroundStyle(blue)
            }
            .padding(14)
            .activityBackgroundTint(Color.black.opacity(0.6))
            .activitySystemActionForegroundColor(.white)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    icon.padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.attributes.streetName)
                            .font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(context.attributes.zoneLabel)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    timer(context)
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(blue)
                        .padding(.trailing, 4)
                }
            } compactLeading: {
                Image(systemName: "parkingsign")
                    .foregroundStyle(blue)
            } compactTrailing: {
                timer(context)
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(blue)
                    .frame(maxWidth: 54)
            } minimal: {
                Image(systemName: "parkingsign")
                    .foregroundStyle(blue)
            }
        }
    }

    private var icon: some View {
        ZStack {
            Circle().fill(blue.opacity(0.25)).frame(width: 34, height: 34)
            Image(systemName: "parkingsign")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(blue)
        }
    }

    @ViewBuilder
    private func timer(_ context: ActivityViewContext<ParkingActivityAttributes>) -> some View {
        if let end = context.state.endDate {
            Text(timerInterval: context.state.startedAt...end, countsDown: true)
        } else {
            Text(context.state.startedAt, style: .timer)
        }
    }
}
