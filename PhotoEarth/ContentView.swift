//
//  ContentView.swift
//  PhotoEarth
//
//  Created by doupi on 2026/9/4.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var model: AppModel

    @MainActor
    init(model: AppModel) {
        _model = StateObject(wrappedValue: model)
    }

    @MainActor
    init() {
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                ScanningView()
            case .welcome:
                WelcomeView(
                    begin: { Task { await model.requestAccessAndScan() } },
                    showDemo: model.useSampleData
                )
            case .scanning:
                ScanningView()
            case .globe:
                GlobeView(model: model)
            case .empty:
                MessageView(
                    symbol: "location.slash",
                    title: "还没有找到带地点的照片",
                    message: "请确认 iPhone 拍照时开启了定位。你也可以先进入示例旅程，体验完整界面。",
                    primaryTitle: "查看示例旅程",
                    primaryAction: model.useSampleData,
                    secondaryTitle: "重新扫描",
                    secondaryAction: { Task { await model.rescan() } }
                )
            case .denied:
                MessageView(
                    symbol: "lock.shield",
                    title: "需要照片访问权限",
                    message: "Photo Earth 只在设备上读取照片的地点和时间。你可以在 Apple TV 设置中允许访问，或先浏览示例旅程。",
                    primaryTitle: "查看示例旅程",
                    primaryAction: model.useSampleData,
                    secondaryTitle: "再次请求",
                    secondaryAction: { Task { await model.requestAccessAndScan() } }
                )
            case .failed(let message):
                MessageView(
                    symbol: "exclamationmark.triangle",
                    title: "旅行地球生成失败",
                    message: message,
                    primaryTitle: "重试",
                    primaryAction: { Task { await model.rescan() } },
                    secondaryTitle: "查看示例旅程",
                    secondaryAction: model.useSampleData
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .ignoresSafeArea()
        .task { await model.start() }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    ContentView()
}
