// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

struct ScheduledCall: Decodable, Identifiable, Sendable {
    let id: UUID
    let contact_id: String
    let source: String
    let next_at: String
    let daily_time: String?
    let time_zone: String?
    var enabled: Bool
    let week_day: Int?
}

extension ExternalCallClient {
    func schedules(connection: ConnectionProfile) async throws -> [ScheduledCall] {
        let result: ScheduleList = try await request(connection, path: ["schedules"], method: "GET", body: Optional<Int>.none)
        return result.schedules
    }

    func saveSchedule(connection: ConnectionProfile, requestID: UUID, id: UUID, roleID: UUID, time: String, timeZone: String, enabled: Bool = true, weekDay: Int? = nil) async throws {
        guard weekDay == nil || (1...7).contains(weekDay!) else { throw TincallError(message: String(localized: "请选择有效的重复日期")) }
        guard TimeZone(identifier: timeZone) != nil else { throw TincallError(message: String(localized: "请选择有效时区")) }
        let capabilities: ScheduleCapabilities = try await request(connection, path: ["capabilities"], method: "GET", body: Optional<Int>.none)
        guard capabilities.schedule_controls == true else {
            throw TincallError(message: String(localized: "请先按原部署方式更新云端服务，再保存新的定时来电设置。"))
        }
        let result: ScheduleResponse = try await request(connection, path: ["schedules"], method: "POST",
            body: ScheduleRequest(request_id: requestID, schedule_id: id, contact_id: roleID.uuidString, source: "independent", daily_time: time, time_zone: timeZone, enabled: enabled, week_day: weekDay))
        guard result.ok else { throw TincallError(message: String(localized: "连接端未确认定时来电")) }
        let saved = try await schedules(connection: connection).first { $0.id == id }
        guard saved?.week_day == weekDay, saved?.enabled == enabled else {
            throw TincallError(message: String(localized: "云端未保存所选的重复方式或启用状态，请按原部署方式更新云端服务后重试。"))
        }
    }

    func setScheduleEnabled(connection: ConnectionProfile, requestID: UUID, id: UUID, enabled: Bool) async throws {
        let result: ScheduleResponse = try await request(connection, path: ["schedules", "enabled"], method: "POST",
            body: ScheduleEnabledRequest(request_id: requestID, schedule_id: id, enabled: enabled))
        guard result.ok else { throw TincallError(message: String(localized: "连接端未确认定时来电状态")) }
    }

    func removeSchedule(connection: ConnectionProfile, requestID: UUID, id: UUID) async throws {
        let result: ScheduleResponse = try await request(connection, path: ["schedules", "remove"], method: "POST",
            body: RemoveSchedule(request_id: requestID, schedule_id: id))
        guard result.ok else { throw TincallError(message: String(localized: "连接端未确认移除定时来电")) }
    }

    private struct ScheduleCapabilities: Decodable { let schedule_controls: Bool? }
    private struct ScheduleList: Decodable { let schedules: [ScheduledCall] }
    private struct ScheduleResponse: Decodable { let ok: Bool }
    private struct ScheduleRequest: Encodable {
        let request_id: UUID
        let schedule_id: UUID
        let contact_id: String
        let source: String
        let daily_time: String
        let time_zone: String
        let enabled: Bool
        let week_day: Int?
    }
    private struct ScheduleEnabledRequest: Encodable { let request_id: UUID; let schedule_id: UUID; let enabled: Bool }
    private struct RemoveSchedule: Encodable { let request_id: UUID; let schedule_id: UUID }
}
