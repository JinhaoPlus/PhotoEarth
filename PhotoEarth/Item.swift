//
//  Item.swift
//  PhotoEarth
//
//  Created by doupi on 2026/9/4.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
