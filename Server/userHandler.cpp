#include "userHandler.h"
#include <nlohmann/json.hpp>
#include <iostream>
#include <jwt-cpp/jwt.h>
#include <fstream>
#include <vector>
#include <bcrypt.h>
#include <string>
#include <queue>

#pragma comment(lib, "bcrypt.lib")

using json = nlohmann::json;

struct SseSession {
    std::string uid;
    std::string chatId;

    std::atomic<bool> alive{ true };

    std::mutex mtx;
    std::deque<std::string> pending;   // 待发送消息
};

inline std::vector<std::shared_ptr<SseSession>> g_sse_subscribers;
inline std::mutex g_sse_mutex;

const std::string kJwtSecret = "your-256-bit-secret"; // 放配置，勿硬编码到代码仓库
const int kJwtExpireSeconds = 3600; // 1 小时

std::string hashPassword(const std::string& password) {
    BCRYPT_ALG_HANDLE hAlg = nullptr;
    BCRYPT_HASH_HANDLE hHash = nullptr;
    DWORD hashLen = 0, cbData = 0;

    BCryptOpenAlgorithmProvider(
        &hAlg,
        BCRYPT_SHA256_ALGORITHM,
        nullptr,
        0
    );

    BCryptGetProperty(
        hAlg,
        BCRYPT_HASH_LENGTH,
        (PUCHAR)&hashLen,
        sizeof(DWORD),
        &cbData,
        0
    );

    std::vector<BYTE> hash(hashLen);

    BCryptCreateHash(
        hAlg,
        &hHash,
        nullptr,
        0,
        nullptr,
        0,
        0
    );

    BCryptHashData(
        hHash,
        (PUCHAR)password.data(),
        password.size(),
        0
    );

    BCryptFinishHash(
        hHash,
        hash.data(),
        hashLen,
        0
    );

    BCryptDestroyHash(hHash);
    BCryptCloseAlgorithmProvider(hAlg, 0);

    // 转 hex
    static const char* hex = "0123456789abcdef";
    std::string out;
    out.reserve(hash.size() * 2);
    for (BYTE b : hash) {
        out.push_back(hex[b >> 4]);
        out.push_back(hex[b & 0xF]);
    }
    return out;
}

static json make_resp(int code, const std::string& msg, json data = json::object()) {
    return json{ {"code", code}, {"message", msg}, {"data", data} };
}

void register_user_routes(httplib::Server& srv, sqlite3* db) {
    // 注册
    srv.Post("/api/register", [db](const httplib::Request& req, httplib::Response& res) {
        res.set_header("Content-Type", "application/json; charset=utf-8");
        json body;
        try { body = json::parse(req.body); }
        catch (...) {
            res.status = 400;
            res.set_content(make_resp(400, "invalid json").dump(), "application/json");
            return;
        }

        const std::string uid = body.value("uid", "");
        const std::string name = body.value("name", "");
        const std::string passwordRaw = body.value("password", "");
        const std::string password = hashPassword(passwordRaw);

      /*  const std::string password = body.value("password", "");*/
    

        if (uid.empty() || name.empty() || password.empty()) {
            res.status = 400;
            res.set_content(make_resp(400, "uid/name/password required").dump(), "application/json");
            return;
        }

        // 检查是否存在
        {
            sqlite3_stmt* stmt = nullptr;
            const char* sql = "SELECT 1 FROM users WHERE id = ? LIMIT 1";
            sqlite3_prepare_v2(db, sql, -1, &stmt, nullptr);
            sqlite3_bind_text(stmt, 1, uid.c_str(), -1, SQLITE_TRANSIENT);
            int rc = sqlite3_step(stmt);
            bool exists = (rc == SQLITE_ROW);
            sqlite3_finalize(stmt);
            if (exists) {
                res.status = 409;
                res.set_content(make_resp(409, "uid exists").dump(), "application/json");
                return;
            }
        }

        // 插入
        {
            sqlite3_stmt* stmt = nullptr;
            const char* sql = "INSERT INTO users(id, name, avatar, passwordHash) VALUES(?,?,NULL,?)";
            sqlite3_prepare_v2(db, sql, -1, &stmt, nullptr);
            sqlite3_bind_text(stmt, 1, uid.c_str(), -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(stmt, 2, name.c_str(), -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(stmt, 3, password.c_str(), -1, SQLITE_TRANSIENT); // 简化：明文
            int rc = sqlite3_step(stmt);
            sqlite3_finalize(stmt);
            if (rc != SQLITE_DONE) {
                res.status = 500;
                res.set_content(make_resp(500, "db insert failed").dump(), "application/json");
                return;
            }
        }

        res.status = 200;
        res.set_content(make_resp(0, "ok").dump(), "application/json");
        });

    // 登录
    srv.Post("/api/login", [db](const httplib::Request& req, httplib::Response& res) {
        res.set_header("Content-Type", "application/json; charset=utf-8");
        json body;
        try { body = json::parse(req.body); }
        catch (...) {
            res.status = 400;
            res.set_content(make_resp(400, "invalid json").dump(), "application/json");
            return;
        }

        const std::string uid = body.value("uid", "");
        const std::string passwordRaw = body.value("password", "");
        const std::string password = hashPassword(passwordRaw);
     /*   const std::string password = body.value("password", "");*/
        if (uid.empty() || password.empty()) {
            res.status = 400;
            res.set_content(make_resp(400, "uid/password required").dump(), "application/json");
            return;
        }

        sqlite3_stmt* stmt = nullptr;
        const char* sql = "SELECT id, name, avatar, passwordHash FROM users WHERE id = ? LIMIT 1";
        sqlite3_prepare_v2(db, sql, -1, &stmt, nullptr);
        sqlite3_bind_text(stmt, 1, uid.c_str(), -1, SQLITE_TRANSIENT);

        int rc = sqlite3_step(stmt);
        if (rc != SQLITE_ROW) {
            sqlite3_finalize(stmt);
            res.status = 404;
            res.set_content(make_resp(404, "user not found").dump(), "application/json");
            return;
        }

        std::string stored_pwd = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 3));
        std::string name = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 1));
        const unsigned char* avatar_text = sqlite3_column_text(stmt, 2);
        std::string avatar = avatar_text ? reinterpret_cast<const char*>(avatar_text) : "";
        sqlite3_finalize(stmt);

        if (stored_pwd != password) {
            res.status = 401;
            res.set_content(make_resp(401, "wrong password").dump(), "application/json");
            return;
        }

        auto token = jwt::create()
            .set_issuer("your-app")
            .set_audience("your-app-client")
            .set_subject(uid)
            .set_issued_at(std::chrono::system_clock::now())
            .set_expires_at(std::chrono::system_clock::now() + std::chrono::seconds(kJwtExpireSeconds))
            .sign(jwt::algorithm::hs256{ kJwtSecret });

        // 写回 users 表
        sqlite3_stmt* stmt_upd = nullptr;
        const char* sql_upd = "UPDATE users SET token = ? WHERE id = ?";
        if (sqlite3_prepare_v2(db, sql_upd, -1, &stmt_upd, nullptr) == SQLITE_OK) {
            sqlite3_bind_text(stmt_upd, 1, token.c_str(), -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(stmt_upd, 2, uid.c_str(), -1, SQLITE_TRANSIENT);
            if (sqlite3_step(stmt_upd) != SQLITE_DONE) {
                std::cerr << "update token failed: " << sqlite3_errmsg(db) << "\n";
            }
            sqlite3_finalize(stmt_upd);
        }
        else {
            std::cerr << "prepare update token failed: " << sqlite3_errmsg(db) << "\n";
        }



        json data{
            {"uid", uid},
            {"name", name},
            {"avatar", avatar.empty() ? nullptr : json(avatar)},
            { "token", token }
        };

        res.status = 200;
        res.set_content(make_resp(0, "ok", data).dump(), "application/json");
        });


	// 批量查询用户信息 /api/users/batch?ids=uid1,uid2,uid3
    srv.Get("/api/users/batch", [db](const httplib::Request& req, httplib::Response& res) {
        res.set_header("Content-Type", "application/json; charset=utf-8");

        // 1) Bearer 校验
        const auto auth = req.get_header_value("Authorization");
        if (auth.rfind("Bearer ", 0) != 0) {
            res.status = 401;
            res.set_content(make_resp(401, "missing bearer").dump(), "application/json");
            return;
        }
        const std::string token = auth.substr(7);

        // 2) token -> caller uid
        const char* sql_uid = "SELECT id FROM users WHERE token = ?";
        sqlite3_stmt* stmt_uid = nullptr;
        if (sqlite3_prepare_v2(db, sql_uid, -1, &stmt_uid, nullptr) != SQLITE_OK) {
            res.status = 500;
            res.set_content(make_resp(500, std::string("db prepare uid error: ") + sqlite3_errmsg(db)).dump(),
                "application/json");
            return;
        }
        sqlite3_bind_text(stmt_uid, 1, token.c_str(), -1, SQLITE_TRANSIENT);
        std::string caller_uid;
        if (sqlite3_step(stmt_uid) == SQLITE_ROW) {
            caller_uid = reinterpret_cast<const char*>(sqlite3_column_text(stmt_uid, 0));
        }
        sqlite3_finalize(stmt_uid);
        if (caller_uid.empty()) {
            res.status = 401;
            res.set_content(make_resp(401, "invalid token").dump(), "application/json");
            return;
        }

        // 3) 解析 ids
        if (!req.has_param("ids")) {
            res.status = 400;
            res.set_content(make_resp(400, "missing ids").dump(), "application/json");
            return;
        }
        const std::string ids_param = req.get_param_value("ids");
        std::vector<std::string> ids;
        {
            std::stringstream ss(ids_param);
            std::string item;
            while (std::getline(ss, item, ',')) {
                if (!item.empty()) ids.push_back(item);
            }
        }
        if (ids.empty()) {
            res.status = 400;
            res.set_content(make_resp(400, "empty ids").dump(), "application/json");
            return;
        }

        // 4) 构造 IN 占位
        std::string placeholders;
        placeholders.reserve(ids.size() * 2);
        for (size_t i = 0; i < ids.size(); ++i) {
            if (i) placeholders += ',';
            placeholders += '?';
        }
        const std::string sql =
            "SELECT id, name, avatar FROM users WHERE id IN (" + placeholders + ")";

        sqlite3_stmt* stmt = nullptr;
        if (sqlite3_prepare_v2(db, sql.c_str(), -1, &stmt, nullptr) != SQLITE_OK) {
            res.status = 500;
            res.set_content(make_resp(500, std::string("db prepare error: ") + sqlite3_errmsg(db)).dump(),
                "application/json");
            return;
        }
        for (size_t i = 0; i < ids.size(); ++i) {
            sqlite3_bind_text(stmt, static_cast<int>(i + 1), ids[i].c_str(), -1, SQLITE_TRANSIENT);
        }

        nlohmann::json arr = nlohmann::json::array();
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            nlohmann::json j;
            j["id"] = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 0));
            j["name"] = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 1));
            const unsigned char* av = sqlite3_column_text(stmt, 2);
            j["avatar"] = av ? reinterpret_cast<const char*>(av) : nullptr;
            arr.push_back(std::move(j));
        }
        sqlite3_finalize(stmt);

        res.status = 200;
        res.set_content(make_resp(0, "ok", arr).dump(), "application/json");
        });


	// 更改用户名
    srv.Put("/api/users/name", [db](const httplib::Request& req, httplib::Response& res) {
        std::cerr << "[PUT /api/users/name] hit\n";
        res.set_header("Content-Type", "application/json; charset=utf-8");

        // Bearer
        const auto auth = req.get_header_value("Authorization");
        if (auth.rfind("Bearer ", 0) != 0) { res.status = 401; res.set_content(make_resp(401, "missing bearer").dump(), "application/json"); return; }
        const std::string token = auth.substr(7);

        // token -> uid
        sqlite3_stmt* stmt_uid = nullptr;
        const char* sql_uid = "SELECT id FROM users WHERE token = ?";
        if (sqlite3_prepare_v2(db, sql_uid, -1, &stmt_uid, nullptr) != SQLITE_OK) {
            res.status = 500; res.set_content(make_resp(500, "db prepare uid error").dump(), "application/json"); return;
        }
        sqlite3_bind_text(stmt_uid, 1, token.c_str(), -1, SQLITE_TRANSIENT);
        std::string uid;
        if (sqlite3_step(stmt_uid) == SQLITE_ROW) {
            uid = reinterpret_cast<const char*>(sqlite3_column_text(stmt_uid, 0));
        }
        sqlite3_finalize(stmt_uid);
        std::cerr << "[PUT /api/users/name] token uid=" << uid << "\n";
        if (uid.empty()) { res.status = 401; res.set_content(make_resp(401, "invalid token").dump(), "application/json"); return; }

        // parse body
        nlohmann::json body;
        try { body = nlohmann::json::parse(req.body); }
        catch (...) { res.status = 400; res.set_content(make_resp(400, "invalid json").dump(), "application/json"); return; }
        const std::string new_name = body.value("name", "");
        if (new_name.empty()) { res.status = 400; res.set_content(make_resp(400, "name required").dump(), "application/json"); return; }

        // update
        sqlite3_stmt* stmt_upd = nullptr;
        const char* sql_upd = "UPDATE users SET name = ? WHERE id = ?";
        if (sqlite3_prepare_v2(db, sql_upd, -1, &stmt_upd, nullptr) != SQLITE_OK) {
            res.status = 500; res.set_content(make_resp(500, "db prepare update error").dump(), "application/json"); return;
        }
        sqlite3_bind_text(stmt_upd, 1, new_name.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt_upd, 2, uid.c_str(), -1, SQLITE_TRANSIENT);
        int rc = sqlite3_step(stmt_upd);
        int changes = sqlite3_changes(db);
        std::cerr << "[PUT /api/users/name] rc=" << rc << " changes=" << changes
            << " err=" << sqlite3_errmsg(db) << "\n";
        sqlite3_finalize(stmt_upd);
        if (rc != SQLITE_DONE) { res.status = 500; res.set_content(make_resp(500, "db update failed").dump(), "application/json"); return; }

        nlohmann::json data{ {"id", uid},{"name", new_name} };
        res.status = 200;
        res.set_content(make_resp(0, "ok", data).dump(), "application/json");
        });


    // 头像上传：POST /api/users/avatar   form-data field: file
    srv.Post("/api/users/avatar", [db](const httplib::Request& req, httplib::Response& res) {
        res.set_header("Content-Type", "application/json; charset=utf-8");

        // 检查 multipart
        if (!req.is_multipart_form_data()) {
            res.status = 400;
            res.set_content(make_resp(400, "expect multipart/form-data").dump(), "application/json");
            return;
        }

        // Bearer 校验
        const auto auth = req.get_header_value("Authorization");
        if (auth.rfind("Bearer ", 0) != 0) {
            res.status = 401;
            res.set_content(make_resp(401, "missing bearer").dump(), "application/json");
            return;
        }
        const std::string token = auth.substr(7);

        // token -> uid
        const char* sql_uid = "SELECT id FROM users WHERE token = ?";
        sqlite3_stmt* stmt_uid = nullptr;
        if (sqlite3_prepare_v2(db, sql_uid, -1, &stmt_uid, nullptr) != SQLITE_OK) {
            res.status = 500;
            res.set_content(make_resp(500, std::string("db prepare uid error: ") + sqlite3_errmsg(db)).dump(), "application/json");
            return;
        }
        sqlite3_bind_text(stmt_uid, 1, token.c_str(), -1, SQLITE_TRANSIENT);
        std::string uid;
        if (sqlite3_step(stmt_uid) == SQLITE_ROW) {
            uid = reinterpret_cast<const char*>(sqlite3_column_text(stmt_uid, 0));
        }
        sqlite3_finalize(stmt_uid);
        if (uid.empty()) {
            res.status = 401;
            res.set_content(make_resp(401, "invalid token").dump(), "application/json");
            return;
        }

        // 取文件字段 file
        auto it = req.files.find("file");
        if (it == req.files.end()) {
            res.status = 400;
            res.set_content(make_resp(400, "missing file field").dump(), "application/json");
            return;
        }
        const auto& file = it->second;

        // 保存到 ./public/avatars/<uid>.png
        const std::string dir = "./public/avatars";
        std::filesystem::create_directories(dir);
        const std::string save_path = dir + "/" + uid + ".png";
        {
            std::ofstream ofs(save_path, std::ios::binary);
            ofs.write(file.content.data(), static_cast<std::streamsize>(file.content.size()));
            if (!ofs.good()) {
                res.status = 500;
                res.set_content(make_resp(500, "write file failed").dump(), "application/json");
                return;
            }
        }

        // 生成 URL（替换为你的实际 baseUrl）
        const std::string baseUrl = "http://127.0.0.1:8080";
        const auto now = std::chrono::system_clock::to_time_t(std::chrono::system_clock::now());
        const std::string url = baseUrl + "/avatars/" + uid + ".png?ts=" + std::to_string(now);

        // 更新 users.avatar
        sqlite3_stmt* stmt_upd = nullptr;
        const char* sql_upd = "UPDATE users SET avatar = ? WHERE id = ?";
        if (sqlite3_prepare_v2(db, sql_upd, -1, &stmt_upd, nullptr) != SQLITE_OK) {
            res.status = 500;
            res.set_content(make_resp(500, std::string("db prepare update error: ") + sqlite3_errmsg(db)).dump(), "application/json");
            return;
        }
        sqlite3_bind_text(stmt_upd, 1, url.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt_upd, 2, uid.c_str(), -1, SQLITE_TRANSIENT);
        int rc = sqlite3_step(stmt_upd);
        sqlite3_finalize(stmt_upd);
        if (rc != SQLITE_DONE) {
            res.status = 500;
            res.set_content(make_resp(500, "db update failed").dump(), "application/json");
            return;
        }

        nlohmann::json data{ {"url", url} };
        res.status = 200;
        res.set_content(make_resp(0, "ok", data).dump(), "application/json");
        });





}

void register_contacts_route(httplib::Server& srv, sqlite3* db) {

    srv.Get("/api/contacts", [db](const httplib::Request& req, httplib::Response& res) {
        res.set_header("Content-Type", "application/json; charset=utf-8");

        // 1) 读取 Authorization: Bearer <token>
        const auto auth = req.get_header_value("Authorization");
        if (auth.rfind("Bearer ", 0) != 0) {
            res.status = 401;
            res.set_content(make_resp(401, "missing bearer").dump(), "application/json");
            return;
        }
        const std::string token = auth.substr(7);

        // 2) token -> uid（改查 users 表的 token 列）
        const char* sql_uid = "SELECT id FROM users WHERE token = ?";
        sqlite3_stmt* stmt_uid = nullptr;
        if (sqlite3_prepare_v2(db, sql_uid, -1, &stmt_uid, nullptr) != SQLITE_OK) {
            auto err = sqlite3_errmsg(db);
            std::cerr << "[contacts] prepare uid failed: " << err << "\n";
            res.status = 500;
            res.set_content(make_resp(500, std::string("db prepare uid error: ") + err).dump(),
                "application/json");
            return;
        }
        sqlite3_bind_text(stmt_uid, 1, token.c_str(), -1, SQLITE_TRANSIENT);

        std::string uid;
        if (sqlite3_step(stmt_uid) == SQLITE_ROW) {
            uid = reinterpret_cast<const char*>(sqlite3_column_text(stmt_uid, 0));
        }
        sqlite3_finalize(stmt_uid);

        if (uid.empty()) {
            res.status = 401;
            res.set_content(make_resp(401, "invalid token").dump(), "application/json");
            return;
        }

        // 3) 查联系人（contacts 表：contactId1, contactId2, status, createdAt）
        const char* sql =
            "SELECT contactId1, contactId2, status, createdAt "
            "FROM contacts "
            "WHERE (contactId1 = ? OR contactId2 = ?) AND status = 'accepted'";

        sqlite3_stmt* stmt = nullptr;
        if (sqlite3_prepare_v2(db, sql, -1, &stmt, nullptr) != SQLITE_OK) {
            auto err = sqlite3_errmsg(db);
            std::cerr << "[contacts] prepare contacts failed: " << err << "\n";
            res.status = 500;
            res.set_content(make_resp(500, std::string("db prepare contacts error: ") + err).dump(),
                "application/json");
            return;
        }
        sqlite3_bind_text(stmt, 1, uid.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 2, uid.c_str(), -1, SQLITE_TRANSIENT);

        json arr = json::array();
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            arr.push_back({
                {"contactId1", reinterpret_cast<const char*>(sqlite3_column_text(stmt, 0))},
                {"contactId2", reinterpret_cast<const char*>(sqlite3_column_text(stmt, 1))},
                {"status",     reinterpret_cast<const char*>(sqlite3_column_text(stmt, 2))},
                {"createdAt",  sqlite3_column_int64(stmt, 3)},
                });
        }
        sqlite3_finalize(stmt);

        res.status = 200;
        res.set_content(make_resp(0, "ok", arr).dump(), "application/json");
        });

    srv.Post("/api/contacts/add", [db](const httplib::Request& req, httplib::Response& res) {
        res.set_header("Content-Type", "application/json; charset=utf-8");

        // 1) 取 Authorization: Bearer <token>
        const auto auth = req.get_header_value("Authorization");
        if (auth.rfind("Bearer ", 0) != 0) {
            res.status = 401;
            res.set_content(make_resp(401, "missing bearer").dump(), "application/json");
            return;
        }
        const std::string token = auth.substr(7);

        // 2) token -> uid（查 users.token）
        const char* sql_uid = "SELECT id FROM users WHERE token = ?";
        sqlite3_stmt* stmt_uid = nullptr;
        if (sqlite3_prepare_v2(db, sql_uid, -1, &stmt_uid, nullptr) != SQLITE_OK) {
            auto err = sqlite3_errmsg(db);
            res.status = 500;
            res.set_content(make_resp(500, std::string("db prepare uid error: ") + err).dump(), "application/json");
            return;
        }
        sqlite3_bind_text(stmt_uid, 1, token.c_str(), -1, SQLITE_TRANSIENT);

        std::string uid;
        if (sqlite3_step(stmt_uid) == SQLITE_ROW) {
            uid = reinterpret_cast<const char*>(sqlite3_column_text(stmt_uid, 0));
        }
        sqlite3_finalize(stmt_uid);
        if (uid.empty()) {
            res.status = 401;
            res.set_content(make_resp(401, "invalid token").dump(), "application/json");
            return;
        }

        // 3) 解析 body: { "targetId": "..." }
        std::string targetId;
        try {
            auto body = json::parse(req.body);
            targetId = body.value("targetId", "");
        }
        catch (...) {
            res.status = 400;
            res.set_content(make_resp(400, "invalid json").dump(), "application/json");
            return;
        }
        if (targetId.empty()) {
            res.status = 400;
            res.set_content(make_resp(400, "missing targetId").dump(), "application/json");
            return;
        }
        if (targetId == uid) {
            res.status = 400;
            res.set_content(make_resp(400, "cannot add yourself").dump(), "application/json");
            return;
        }

        // 4) 检查目标用户存在
        const char* sql_chk_user = "SELECT 1 FROM users WHERE id = ? LIMIT 1";
        sqlite3_stmt* stmt_chk = nullptr;
        if (sqlite3_prepare_v2(db, sql_chk_user, -1, &stmt_chk, nullptr) != SQLITE_OK) {
            auto err = sqlite3_errmsg(db);
            res.status = 500;
            res.set_content(make_resp(500, std::string("db prepare check user error: ") + err).dump(), "application/json");
            return;
        }
        sqlite3_bind_text(stmt_chk, 1, targetId.c_str(), -1, SQLITE_TRANSIENT);
        bool target_exists = (sqlite3_step(stmt_chk) == SQLITE_ROW);
        sqlite3_finalize(stmt_chk);
        if (!target_exists) {
            res.status = 404;
            res.set_content(make_resp(404, "target user not found").dump(), "application/json");
            return;
        }

        // 5) 检查联系人是否已存在（双向）
        const char* sql_exists =
            "SELECT id, status FROM contacts "
            "WHERE (contactId1 = ? AND contactId2 = ?) OR (contactId1 = ? AND contactId2 = ?) "
            "LIMIT 1";
        sqlite3_stmt* stmt_exist = nullptr;
        if (sqlite3_prepare_v2(db, sql_exists, -1, &stmt_exist, nullptr) != SQLITE_OK) {
            auto err = sqlite3_errmsg(db);
            res.status = 500;
            res.set_content(make_resp(500, std::string("db prepare exists error: ") + err).dump(), "application/json");
            return;
        }
        sqlite3_bind_text(stmt_exist, 1, uid.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt_exist, 2, targetId.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt_exist, 3, targetId.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt_exist, 4, uid.c_str(), -1, SQLITE_TRANSIENT);

        std::string existingStatus;
        if (sqlite3_step(stmt_exist) == SQLITE_ROW) {
            existingStatus = reinterpret_cast<const char*>(sqlite3_column_text(stmt_exist, 1));
        }
        sqlite3_finalize(stmt_exist);

        if (!existingStatus.empty()) {
            // 已存在，直接返回
            res.status = 200;
            res.set_content(make_resp(0, "already exists", { {"status", existingStatus} }).dump(),
                "application/json");
            return;
        }

        // 6) 插入联系人（这里直接 accepted；如需好友申请，可用 pending）
        const char* sql_ins =
            "INSERT INTO contacts (contactId1, contactId2, status, createdAt) "
            "VALUES (?, ?, 'accepted', ?)";
        sqlite3_stmt* stmt_ins = nullptr;
        if (sqlite3_prepare_v2(db, sql_ins, -1, &stmt_ins, nullptr) != SQLITE_OK) {
            auto err = sqlite3_errmsg(db);
            res.status = 500;
            res.set_content(make_resp(500, std::string("db prepare insert error: ") + err).dump(),
                "application/json");
            return;
        }
        const auto now_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::system_clock::now().time_since_epoch())
            .count();
        sqlite3_bind_text(stmt_ins, 1, uid.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt_ins, 2, targetId.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(stmt_ins, 3, now_ms);

        if (sqlite3_step(stmt_ins) != SQLITE_DONE) {
            auto err = sqlite3_errmsg(db);
            sqlite3_finalize(stmt_ins);
            res.status = 500;
            res.set_content(make_resp(500, std::string("insert contact failed: ") + err).dump(),
                "application/json");
            return;
        }
        sqlite3_finalize(stmt_ins);

        res.status = 200;
        res.set_content(make_resp(0, "ok", { {"status", "accepted"} }).dump(), "application/json");
        });



}

void register_chats_route(httplib::Server& srv, sqlite3* db) {

    // 批量查询：返回与当前用户相关的 chats
    srv.Get("/api/chats", [db](const httplib::Request& req, httplib::Response& res) {
        res.set_header("Content-Type", "application/json; charset=utf-8");

        // 1) Bearer token
        const auto auth = req.get_header_value("Authorization");
        if (auth.rfind("Bearer ", 0) != 0) {
            res.status = 401;
            res.set_content(make_resp(401, "missing bearer").dump(), "application/json");
            return;
        }
        const std::string token = auth.substr(7);

        // 2) token -> uid
        const char* sql_uid = "SELECT id FROM users WHERE token = ?";
        sqlite3_stmt* stmt_uid = nullptr;
        if (sqlite3_prepare_v2(db, sql_uid, -1, &stmt_uid, nullptr) != SQLITE_OK) {
            auto err = sqlite3_errmsg(db);
            res.status = 500;
            res.set_content(make_resp(500, std::string("db prepare uid error: ") + err).dump(),
                "application/json");
            return;
        }
        sqlite3_bind_text(stmt_uid, 1, token.c_str(), -1, SQLITE_TRANSIENT);

        std::string uid;
        if (sqlite3_step(stmt_uid) == SQLITE_ROW) {
            uid = reinterpret_cast<const char*>(sqlite3_column_text(stmt_uid, 0));
        }
        sqlite3_finalize(stmt_uid);
        if (uid.empty()) {
            res.status = 401;
            res.set_content(make_resp(401, "invalid token").dump(), "application/json");
            return;
        }

        // 3) 查 chats：participantIds LIKE '%uid%'
        // 为了避免 u1 匹配 u11，这里拼四种模式。
        const char* sql =
            "SELECT id, name, participantIds, lastMessage, lastMessageTime, unreadCount "
            "FROM chats "
            "WHERE participantIds = ? "
            "   OR participantIds LIKE ? "
            "   OR participantIds LIKE ? "
            "   OR participantIds LIKE ?";

        sqlite3_stmt* stmt = nullptr;
        if (sqlite3_prepare_v2(db, sql, -1, &stmt, nullptr) != SQLITE_OK) {
            auto err = sqlite3_errmsg(db);
            res.status = 500;
            res.set_content(make_resp(500, std::string("db prepare chats error: ") + err).dump(),
                "application/json");
            return;
        }
        // 精确等于
        sqlite3_bind_text(stmt, 1, uid.c_str(), -1, SQLITE_TRANSIENT);
        // 前缀/中间/后缀
        std::string like_mid = "%," + uid + ",%";
        std::string like_head = uid + ",%";
        std::string like_tail = "%," + uid;

        sqlite3_bind_text(stmt, 2, like_mid.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 3, like_head.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 4, like_tail.c_str(), -1, SQLITE_TRANSIENT);

        json arr = json::array();
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            arr.push_back({
                {"id",              reinterpret_cast<const char*>(sqlite3_column_text(stmt, 0))},
                {"name",            reinterpret_cast<const char*>(sqlite3_column_text(stmt, 1))},
                {"participantIds",  reinterpret_cast<const char*>(sqlite3_column_text(stmt, 2))},
                {"lastMessage",     sqlite3_column_type(stmt, 3) == SQLITE_NULL ? "" :
                                     reinterpret_cast<const char*>(sqlite3_column_text(stmt, 3))},
                {"lastMessageTime", sqlite3_column_int64(stmt, 4)},
                {"unreadCount",     sqlite3_column_int64(stmt, 5)}
                });
        }
        sqlite3_finalize(stmt);

        res.status = 200;
        res.set_content(make_resp(0, "ok", arr).dump(), "application/json");
        });

    // 新增一条 chat（简易版：不检查重复，直接插入）
    srv.Post("/api/chats/add", [db](const httplib::Request& req, httplib::Response& res) {
        res.set_header("Content-Type", "application/json; charset=utf-8");

        // 1) Bearer token
        const auto auth = req.get_header_value("Authorization");
        if (auth.rfind("Bearer ", 0) != 0) {
            res.status = 401;
            res.set_content(make_resp(401, "missing bearer").dump(), "application/json");
            return;
        }
        const std::string token = auth.substr(7);

        // 2) token -> uid（仅校验 token）
        const char* sql_uid = "SELECT id FROM users WHERE token = ?";
        sqlite3_stmt* stmt_uid = nullptr;
        if (sqlite3_prepare_v2(db, sql_uid, -1, &stmt_uid, nullptr) != SQLITE_OK) {
            auto err = sqlite3_errmsg(db);
            res.status = 500;
            res.set_content(make_resp(500, std::string("db prepare uid error: ") + err).dump(),
                "application/json");
            return;
        }
        sqlite3_bind_text(stmt_uid, 1, token.c_str(), -1, SQLITE_TRANSIENT);

        std::string uid;
        if (sqlite3_step(stmt_uid) == SQLITE_ROW) {
            uid = reinterpret_cast<const char*>(sqlite3_column_text(stmt_uid, 0));
        }
        sqlite3_finalize(stmt_uid);
        if (uid.empty()) {
            res.status = 401;
            res.set_content(make_resp(401, "invalid token").dump(), "application/json");
            return;
        }

        // 3) 解析 body: { "name": "...", "participantIds": ["u1","u2",...], "lastMessage": "..." }
        std::string name;
        std::vector<std::string> participants;
        std::string lastMessage;
        try {
            auto body = json::parse(req.body);
            name = body.value("name", "");
            lastMessage = body.value("lastMessage", "");
            if (body.contains("participantIds") && body["participantIds"].is_array()) {
                for (auto& v : body["participantIds"]) {
                    if (v.is_string()) participants.push_back(v.get<std::string>());
                }
            }
        }
        catch (...) {
            res.status = 400;
            res.set_content(make_resp(400, "invalid json").dump(), "application/json");
            return;
        }
        if (name.empty() || participants.empty()) {
            res.status = 400;
            res.set_content(make_resp(400, "missing name or participantIds").dump(), "application/json");
            return;
        }

        // 4) 生成 id（简单用时间戳拼随机数）
        const auto now_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::system_clock::now().time_since_epoch()).count();
        const auto rnd = std::rand() % 1000000;
        const std::string chatId = "chat_" + std::to_string(now_ms) + "_" + std::to_string(rnd);

        // 5) participantIds 序列化为逗号分隔
        std::string participantIds;
        for (size_t i = 0; i < participants.size(); ++i) {
            if (i) participantIds.push_back(',');
            participantIds += participants[i];
        }

        // 6) 插入
        const char* sql_ins =
            "INSERT INTO chats (id, name, participantIds, lastMessage, lastMessageTime, unreadCount) "
            "VALUES (?, ?, ?, ?, ?, 0)";
        sqlite3_stmt* stmt_ins = nullptr;
        if (sqlite3_prepare_v2(db, sql_ins, -1, &stmt_ins, nullptr) != SQLITE_OK) {
            auto err = sqlite3_errmsg(db);
            res.status = 500;
            res.set_content(make_resp(500, std::string("db prepare insert error: ") + err).dump(),
                "application/json");
            return;
        }
        sqlite3_bind_text(stmt_ins, 1, chatId.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt_ins, 2, name.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt_ins, 3, participantIds.c_str(), -1, SQLITE_TRANSIENT);
        if (lastMessage.empty()) {
            sqlite3_bind_null(stmt_ins, 4);
        }
        else {
            sqlite3_bind_text(stmt_ins, 4, lastMessage.c_str(), -1, SQLITE_TRANSIENT);
        }
        sqlite3_bind_int64(stmt_ins, 5, now_ms);

        if (sqlite3_step(stmt_ins) != SQLITE_DONE) {
            auto err = sqlite3_errmsg(db);
            sqlite3_finalize(stmt_ins);
            res.status = 500;
            res.set_content(make_resp(500, std::string("insert chat failed: ") + err).dump(),
                "application/json");
            return;
        }
        sqlite3_finalize(stmt_ins);

        res.status = 200;
        res.set_content(make_resp(0, "ok", { {"id", chatId} }).dump(), "application/json");
        });

    // 删除单条chat
    srv.Delete(R"(/api/chats/([A-Za-z0-9_\-\.]+))", [db](const httplib::Request& req, httplib::Response& res) {
        res.set_header("Content-Type", "application/json; charset=utf-8");

        // 1) Bearer token
        const auto auth = req.get_header_value("Authorization");
        if (auth.rfind("Bearer ", 0) != 0) {
            res.status = 401;
            res.set_content(make_resp(401, "missing bearer").dump(), "application/json");
            return;
        }
        const std::string token = auth.substr(7);

        // 2) token -> uid
        const char* sql_uid = "SELECT id FROM users WHERE token = ?";
        sqlite3_stmt* stmt_uid = nullptr;
        if (sqlite3_prepare_v2(db, sql_uid, -1, &stmt_uid, nullptr) != SQLITE_OK) {
            auto err = sqlite3_errmsg(db);
            res.status = 500;
            res.set_content(make_resp(500, std::string("db prepare uid error: ") + err).dump(),
                "application/json");
            return;
        }
        sqlite3_bind_text(stmt_uid, 1, token.c_str(), -1, SQLITE_TRANSIENT);

        std::string uid;
        if (sqlite3_step(stmt_uid) == SQLITE_ROW) {
            uid = reinterpret_cast<const char*>(sqlite3_column_text(stmt_uid, 0));
        }
        sqlite3_finalize(stmt_uid);
        if (uid.empty()) {
            res.status = 401;
            res.set_content(make_resp(401, "invalid token").dump(), "application/json");
            return;
        }

        // 3) 取 chatId
        if (req.matches.size() < 2) {
            res.status = 400;
            res.set_content(make_resp(400, "missing chatId").dump(), "application/json");
            return;
        }
        const std::string chatId = req.matches[1];

        // 4) 确认该聊天存在且包含当前用户
        const char* sql_chk =
            "SELECT 1 FROM chats "
            "WHERE id = ? AND (participantIds = ? "
            "   OR participantIds LIKE ? "
            "   OR participantIds LIKE ? "
            "   OR participantIds LIKE ?)"
            "LIMIT 1";
        sqlite3_stmt* stmt_chk = nullptr;
        if (sqlite3_prepare_v2(db, sql_chk, -1, &stmt_chk, nullptr) != SQLITE_OK) {
            auto err = sqlite3_errmsg(db);
            res.status = 500;
            res.set_content(make_resp(500, std::string("db prepare check error: ") + err).dump(),
                "application/json");
            return;
        }
        std::string like_mid = "%," + uid + ",%";
        std::string like_head = uid + ",%";
        std::string like_tail = "%," + uid;
        sqlite3_bind_text(stmt_chk, 1, chatId.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt_chk, 2, uid.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt_chk, 3, like_head.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt_chk, 4, like_tail.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt_chk, 5, like_mid.c_str(), -1, SQLITE_TRANSIENT);

        bool exists = (sqlite3_step(stmt_chk) == SQLITE_ROW);
        sqlite3_finalize(stmt_chk);
        if (!exists) {
            res.status = 404;
            res.set_content(make_resp(404, "chat not found or no permission").dump(),
                "application/json");
            return;
        }

        // 5) 删除
        const char* sql_del = "DELETE FROM chats WHERE id = ?";
        sqlite3_stmt* stmt_del = nullptr;
        if (sqlite3_prepare_v2(db, sql_del, -1, &stmt_del, nullptr) != SQLITE_OK) {
            auto err = sqlite3_errmsg(db);
            res.status = 500;
            res.set_content(make_resp(500, std::string("db prepare delete error: ") + err).dump(),
                "application/json");
            return;
        }
        sqlite3_bind_text(stmt_del, 1, chatId.c_str(), -1, SQLITE_TRANSIENT);

        if (sqlite3_step(stmt_del) != SQLITE_DONE) {
            auto err = sqlite3_errmsg(db);
            sqlite3_finalize(stmt_del);
            res.status = 500;
            res.set_content(make_resp(500, std::string("delete chat failed: ") + err).dump(),
                "application/json");
            return;
        }
        sqlite3_finalize(stmt_del);

        res.status = 200;
        res.set_content(make_resp(0, "ok").dump(), "application/json");
        });

    // 发送消息
    srv.Post("/api/messages/send", [db](const httplib::Request& req, httplib::Response& res) {
        res.set_header("Content-Type", "application/json; charset=utf-8");

        // 1) Bearer token
        const auto auth = req.get_header_value("Authorization");
        if (auth.rfind("Bearer ", 0) != 0) {
            res.status = 401;
            res.set_content(make_resp(401, "missing bearer").dump(), "application/json");
            return;
        }
        const std::string token = auth.substr(7);

        // 2) token -> uid & name
        const char* sql_uid = "SELECT id, name FROM users WHERE token = ?";
        sqlite3_stmt* stmt_uid = nullptr;
        if (sqlite3_prepare_v2(db, sql_uid, -1, &stmt_uid, nullptr) != SQLITE_OK) {
            auto err = sqlite3_errmsg(db);
            res.status = 500;
            res.set_content(make_resp(500, std::string("db prepare uid error: ") + err).dump(),
                "application/json");
            return;
        }
        sqlite3_bind_text(stmt_uid, 1, token.c_str(), -1, SQLITE_TRANSIENT);

        std::string uid, uname;
        if (sqlite3_step(stmt_uid) == SQLITE_ROW) {
            uid   = reinterpret_cast<const char*>(sqlite3_column_text(stmt_uid, 0));
            uname = reinterpret_cast<const char*>(sqlite3_column_text(stmt_uid, 1));
        }
        sqlite3_finalize(stmt_uid);
        if (uid.empty()) {
            res.status = 401;
            res.set_content(make_resp(401, "invalid token").dump(), "application/json");
            return;
        }

        // 3) 解析 body
        std::string chatId;
        int type = 0;
        std::string content;
        std::string clientMsgId;
        try {
            auto body = json::parse(req.body);
            chatId      = body.value("chatId", "");
            type        = body.value("type", 0);
            content     = body.value("content", "");
            clientMsgId = body.value("clientMsgId", "");
        } catch (...) {
            res.status = 400;
            res.set_content(make_resp(400, "invalid json").dump(), "application/json");
            return;
        }
        if (chatId.empty() || content.empty()) {
            res.status = 400;
            res.set_content(make_resp(400, "missing chatId or content").dump(), "application/json");
            return;
        }
        if (clientMsgId.empty()) {
            const auto now_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::system_clock::now().time_since_epoch()).count();
            const auto rnd = std::rand() % 1000000;
            clientMsgId = "msg_" + std::to_string(now_ms) + "_" + std::to_string(rnd);
        }

        // 4) 校验 chat 参与权限
        const char* sql_chk =
            "SELECT 1 FROM chats "
            "WHERE id = ? AND (participantIds = ? "
            "   OR participantIds LIKE ? "
            "   OR participantIds LIKE ? "
            "   OR participantIds LIKE ?)"
            "LIMIT 1";
        sqlite3_stmt* stmt_chk = nullptr;
        if (sqlite3_prepare_v2(db, sql_chk, -1, &stmt_chk, nullptr) != SQLITE_OK) {
            auto err = sqlite3_errmsg(db);
            res.status = 500;
            res.set_content(make_resp(500, std::string("db prepare check error: ") + err).dump(),
                "application/json");
            return;
        }
        std::string like_mid  = "%," + uid + ",%";
        std::string like_head = uid + ",%";
        std::string like_tail = "%," + uid;
        sqlite3_bind_text(stmt_chk, 1, chatId.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt_chk, 2, uid.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt_chk, 3, like_head.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt_chk, 4, like_tail.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt_chk, 5, like_mid.c_str(), -1, SQLITE_TRANSIENT);

        bool exists = (sqlite3_step(stmt_chk) == SQLITE_ROW);
        sqlite3_finalize(stmt_chk);
        if (!exists) {
            res.status = 404;
            res.set_content(make_resp(404, "chat not found or no permission").dump(),
                "application/json");
            return;
        }

        // 5) 幂等检查：id = clientMsgId
        {
            sqlite3_stmt* stmt = nullptr;
            const char* sql = R"SQL(
              SELECT id, chatId, senderId, senderName, type, content, timestamp, isRead
              FROM messages WHERE id = ? LIMIT 1;
            )SQL";
            sqlite3_prepare_v2(db, sql, -1, &stmt, nullptr);
            sqlite3_bind_text(stmt, 1, clientMsgId.c_str(), -1, SQLITE_TRANSIENT);

            if (sqlite3_step(stmt) == SQLITE_ROW) {
                json data;
                data["id"]         = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 0));
                data["chatId"]     = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 1));
                data["senderId"]   = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 2));
                data["senderName"] = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 3));
                data["type"]       = sqlite3_column_int(stmt, 4);
                data["content"]    = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 5));
                data["timestamp"]  = sqlite3_column_int64(stmt, 6);
                data["isRead"]     = sqlite3_column_int(stmt, 7);
                sqlite3_finalize(stmt);

                res.status = 200;
                res.set_content(make_resp(0, "ok", data).dump(), "application/json");
                return;
            }
            sqlite3_finalize(stmt);
        }

        // 6) 插入新消息
        const int64_t now_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::system_clock::now().time_since_epoch()).count();

        {
            sqlite3_stmt* stmt = nullptr;
            const char* sql = R"SQL(
              INSERT INTO messages (id, chatId, senderId, senderName, type, content, timestamp, isRead)
              VALUES (?, ?, ?, ?, ?, ?, ?, 0);
            )SQL";
            sqlite3_prepare_v2(db, sql, -1, &stmt, nullptr);
            sqlite3_bind_text(stmt, 1, clientMsgId.c_str(), -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(stmt, 2, chatId.c_str(), -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(stmt, 3, uid.c_str(), -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(stmt, 4, uname.c_str(), -1, SQLITE_TRANSIENT);
            sqlite3_bind_int (stmt, 5, type);
            sqlite3_bind_text(stmt, 6, content.c_str(), -1, SQLITE_TRANSIENT);
            sqlite3_bind_int64(stmt, 7, now_ms);

            if (sqlite3_step(stmt) != SQLITE_DONE) {
                auto err = sqlite3_errmsg(db);
                sqlite3_finalize(stmt);
                res.status = 500;
                res.set_content(make_resp(500, std::string("insert message failed: ") + err).dump(),
                    "application/json");
                return;
            }
            sqlite3_finalize(stmt);
        }

        // 7) 更新 chats.lastMessage / lastMessageTime
        {
            sqlite3_stmt* stmt = nullptr;
            const char* sql = R"SQL(
              UPDATE chats SET lastMessage = ?, lastMessageTime = ?
              WHERE id = ?;
            )SQL";
            sqlite3_prepare_v2(db, sql, -1, &stmt, nullptr);

            if (type == 0) { //发送文本
                sqlite3_bind_text(stmt, 1, content.c_str(), -1, SQLITE_TRANSIENT);
            }
            else if (type == 1) { //发送图片
             
                sqlite3_bind_text(stmt, 1, "[picture]", -1, SQLITE_TRANSIENT);
            }
            else if(type == 2){ //发送表情
                sqlite3_bind_text(stmt, 1, "[emoji]", -1, SQLITE_TRANSIENT);
            }
			
     
            sqlite3_bind_int64(stmt, 2, now_ms);
            sqlite3_bind_text(stmt, 3, chatId.c_str(), -1, SQLITE_TRANSIENT);
            sqlite3_step(stmt);
            sqlite3_finalize(stmt);
        }

       
        json data{
            {"id",         clientMsgId},
            {"chatId",     chatId},
            {"senderId",   uid},
            {"senderName", uname},
            {"type",       type},
            {"content",    content},
            {"timestamp",  now_ms},
            {"isRead",     0}
        };


        




        // 8) 广播 SSE（最终安全版，直接写在这里）
        {
            // 构造 SSE payload
            std::string payload =
                "event: message\ndata: " + data.dump() + "\n\n";

            std::lock_guard<std::mutex> lock(g_sse_mutex);

            for (auto it = g_sse_subscribers.begin();
                it != g_sse_subscribers.end(); ) {

                auto& s = *it;

                // 清理已失效的 SSE
                if (!s->alive) {
                    it = g_sse_subscribers.erase(it);
                    continue;
                }

                // chatId 过滤（只推给对应会话）
                if (!s->chatId.empty() && s->chatId != chatId) {
                    ++it;
                    continue;
                }

                {
                    std::lock_guard<std::mutex> lk(s->mtx);
                    s->pending.push_back(payload);
                }

                ++it;
            }
        }

        // 返回


        res.status = 200;
        res.set_content(make_resp(0, "ok", data).dump(), "application/json");
    });

	// 文件上传（如图片）
    srv.Post("/api/files/upload", [db](const httplib::Request& req, httplib::Response& res) {
        res.set_header("Content-Type", "application/json; charset=utf-8");

        // 1) Bearer token
        const auto auth = req.get_header_value("Authorization");
        if (auth.rfind("Bearer ", 0) != 0) {
            res.status = 401;
            res.set_content(make_resp(401, "missing bearer").dump(), "application/json");
            return;
        }
        const std::string token = auth.substr(7);

        // 2) token -> uid（仅校验 token 有效）
        const char* sql_uid = "SELECT id FROM users WHERE token = ?";
        sqlite3_stmt* stmt_uid = nullptr;
        if (sqlite3_prepare_v2(db, sql_uid, -1, &stmt_uid, nullptr) != SQLITE_OK) {
            auto err = sqlite3_errmsg(db);
            res.status = 500;
            res.set_content(make_resp(500, std::string("db prepare uid error: ") + err).dump(),
                "application/json");
            return;
        }
        sqlite3_bind_text(stmt_uid, 1, token.c_str(), -1, SQLITE_TRANSIENT);

        std::string uid;
        if (sqlite3_step(stmt_uid) == SQLITE_ROW) {
            uid = reinterpret_cast<const char*>(sqlite3_column_text(stmt_uid, 0));
        }
        sqlite3_finalize(stmt_uid);
        if (uid.empty()) {
            res.status = 401;
            res.set_content(make_resp(401, "invalid token").dump(), "application/json");
            return;
        }

        // 3) 读取 multipart 字段 "file"
        if (!req.has_file("file")) {
            res.status = 400;
            res.set_content(make_resp(400, "missing file").dump(), "application/json");
            return;
        }
        auto file = req.get_file_value("file");
        const std::string origName = file.filename.empty() ? "upload.bin" : file.filename;

        // 4) 保存到本地 ./uploads/ 目录
        const auto now_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::system_clock::now().time_since_epoch()).count();
        const auto rnd = std::rand() % 1000000;
        const std::string safeName = std::to_string(now_ms) + "_" + std::to_string(rnd) + "_" + origName;

        const std::string saveDir = "./uploads/";
        std::error_code ec;
        std::filesystem::create_directories(saveDir, ec); // 忽略已存在错误
        const std::string savePath = saveDir + safeName;

        std::ofstream ofs(savePath, std::ios::binary);
        ofs.write(file.content.data(), file.content.size());
        ofs.close();

     
        const std::string data_path = "http://127.0.0.1:8080/uploads/" + safeName;
        // 5) 返回存储信息
        json data{
            {"path",  data_path},          // 前端可用作 content 发送
            {"fileName", safeName},
            {"fileSize", static_cast<int64_t>(file.content.size())},
            {"width", nullptr},          // 若需要可在前端解析尺寸后再传
            {"height", nullptr},
            {"createdAt", now_ms}
        };

        res.status = 200;
        res.set_content(make_resp(0, "ok", data).dump(), "application/json");
        });

    // 增量拉取消息：GET /api/messages?chatId=xxx&since=0&limit=200
    srv.Get("/api/messages", [db](const httplib::Request& req, httplib::Response& res) {
        res.set_header("Content-Type", "application/json; charset=utf-8");

        // 1) Bearer token
        const auto auth = req.get_header_value("Authorization");
        if (auth.rfind("Bearer ", 0) != 0) {
            res.status = 401;
            res.set_content(make_resp(401, "missing bearer").dump(), "application/json");
            return;
        }
        const std::string token = auth.substr(7);

        // 2) token -> uid & name
        const char* sql_uid = "SELECT id, name FROM users WHERE token = ?";
        sqlite3_stmt* stmt_uid = nullptr;
        if (sqlite3_prepare_v2(db, sql_uid, -1, &stmt_uid, nullptr) != SQLITE_OK) {
            auto err = sqlite3_errmsg(db);
            res.status = 500;
            res.set_content(make_resp(500, std::string("db prepare uid error: ") + err).dump(),
                "application/json");
            return;
        }
        sqlite3_bind_text(stmt_uid, 1, token.c_str(), -1, SQLITE_TRANSIENT);
        std::string uid, uname;
        if (sqlite3_step(stmt_uid) == SQLITE_ROW) {
            uid = reinterpret_cast<const char*>(sqlite3_column_text(stmt_uid, 0));
            uname = reinterpret_cast<const char*>(sqlite3_column_text(stmt_uid, 1));
        }
        sqlite3_finalize(stmt_uid);
        if (uid.empty()) {
            res.status = 401;
            res.set_content(make_resp(401, "invalid token").dump(), "application/json");
            return;
        }

        // 3) 解析 query 参数
        const auto chatIdParam = req.get_param_value("chatId");
        if (chatIdParam.empty()) {
            res.status = 400;
            res.set_content(make_resp(400, "missing chatId").dump(), "application/json");
            return;
        }

        int64_t since = 0;
        {
            std::string s = req.has_param("since") ? req.get_param_value("since") : "";
            if (!s.empty()) {
                try { since = std::stoll(s); }
                catch (...) {}
            }
        }

        int limit = 200;
        {
            std::string s = req.has_param("limit") ? req.get_param_value("limit") : "200";
            try { limit = std::stoi(s); }
            catch (...) { limit = 200; }
            if (limit <= 0) limit = 50;
            if (limit > 200) limit = 200;
        }

        const std::string& chatId = chatIdParam;

        // 4) 校验 chat 参与权限
        const char* sql_chk =
            "SELECT 1 FROM chats "
            "WHERE id = ? AND (participantIds = ? "
            "   OR participantIds LIKE ? "
            "   OR participantIds LIKE ? "
            "   OR participantIds LIKE ?)"
            "LIMIT 1";
        sqlite3_stmt* stmt_chk = nullptr;
        if (sqlite3_prepare_v2(db, sql_chk, -1, &stmt_chk, nullptr) != SQLITE_OK) {
            auto err = sqlite3_errmsg(db);
            res.status = 500;
            res.set_content(make_resp(500, std::string("db prepare check error: ") + err).dump(),
                "application/json");
            return;
        }
        std::string like_mid = "%," + uid + ",%";
        std::string like_head = uid + ",%";
        std::string like_tail = "%," + uid;
        sqlite3_bind_text(stmt_chk, 1, chatId.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt_chk, 2, uid.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt_chk, 3, like_head.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt_chk, 4, like_tail.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt_chk, 5, like_mid.c_str(), -1, SQLITE_TRANSIENT);

        bool exists = (sqlite3_step(stmt_chk) == SQLITE_ROW);
        sqlite3_finalize(stmt_chk);
        if (!exists) {
            res.status = 404;
            res.set_content(make_resp(404, "chat not found or no permission").dump(),
                "application/json");
            return;
        }

        // 5) 查询消息（created_at/timestamp > since，升序，limit）
        const char* sql_msg = R"SQL(
      SELECT id, chatId, senderId, senderName, type, content, timestamp, isRead
      FROM messages
      WHERE chatId = ? AND timestamp > ?
      ORDER BY timestamp ASC
      LIMIT ?;
    )SQL";
        sqlite3_stmt* stmt_msg = nullptr;
        if (sqlite3_prepare_v2(db, sql_msg, -1, &stmt_msg, nullptr) != SQLITE_OK) {
            auto err = sqlite3_errmsg(db);
            res.status = 500;
            res.set_content(make_resp(500, std::string("db prepare msg error: ") + err).dump(),
                "application/json");
            return;
        }
        sqlite3_bind_text(stmt_msg, 1, chatId.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(stmt_msg, 2, since);
        sqlite3_bind_int(stmt_msg, 3, limit);

        json arr = json::array();
        while (sqlite3_step(stmt_msg) == SQLITE_ROW) {
            json item;
            item["id"] = reinterpret_cast<const char*>(sqlite3_column_text(stmt_msg, 0));
            item["chatId"] = reinterpret_cast<const char*>(sqlite3_column_text(stmt_msg, 1));
            item["senderId"] = reinterpret_cast<const char*>(sqlite3_column_text(stmt_msg, 2));
            item["senderName"] = reinterpret_cast<const char*>(sqlite3_column_text(stmt_msg, 3));
            item["type"] = sqlite3_column_int(stmt_msg, 4);
            item["content"] = reinterpret_cast<const char*>(sqlite3_column_text(stmt_msg, 5));
            item["timestamp"] = sqlite3_column_int64(stmt_msg, 6);
            item["isRead"] = sqlite3_column_int(stmt_msg, 7);
            arr.push_back(std::move(item));
        }
        sqlite3_finalize(stmt_msg);

        // 6) 返回
        json data = arr;
        res.status = 200;
        res.set_content(make_resp(0, "ok", data).dump(), "application/json");
        });


     
               
       
            
}

//订阅路由
void register_realtime_routes(httplib::Server& srv, sqlite3* db) {
    srv.Get("/api/stream", [db](const httplib::Request& req, httplib::Response& res) {

        // --- token -> uid ---
        const auto auth = req.get_header_value("Authorization");
        if (auth.rfind("Bearer ", 0) != 0) {
            res.status = 401;
            return;
        }

        const std::string token = auth.substr(7);
        std::string uid;

        {
            sqlite3_stmt* stmt = nullptr;
            const char* sql = "SELECT id FROM users WHERE token = ?";
            sqlite3_prepare_v2(db, sql, -1, &stmt, nullptr);
            sqlite3_bind_text(stmt, 1, token.c_str(), -1, SQLITE_TRANSIENT);

            if (sqlite3_step(stmt) == SQLITE_ROW) {
                uid = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 0));
            }
            sqlite3_finalize(stmt);
        }

        if (uid.empty()) {
            res.status = 401;
            return;
        }

        const std::string chatId =
            req.has_param("chatId") ? req.get_param_value("chatId") : "";

        // --- SSE headers ---
        res.set_header("Content-Type", "text/event-stream");
        res.set_header("Cache-Control", "no-cache");
        res.set_header("Connection", "keep-alive");

        // --- 创建会话 ---
        auto session = std::make_shared<SseSession>();
        session->uid = uid;
        session->chatId = chatId;

        // --- SSE provider ---
        res.set_chunked_content_provider(
            "text/event-stream",

            // provider
            [session](size_t, httplib::DataSink& sink) {
                std::lock_guard<std::mutex> lk(session->mtx);

                if (!session->alive) {
                    return false;
                }

                while (!session->pending.empty()) {
                    const auto& msg = session->pending.front();
                    if (!sink.write(msg.c_str(), msg.size())) {
                        session->alive = false;
                        return false;
                    }
                    session->pending.pop_front();
                }

                return true;
            },

            // on_complete / on_abort
            [session](bool /*success*/) {
                session->alive = false;
            }
        );
        // --- 注册订阅 ---
        {
            std::lock_guard<std::mutex> lock(g_sse_mutex);
            g_sse_subscribers.push_back(session);
        }
        });
}


// 从中间件或头里拿当前用户 uid
std::string current_uid(const httplib::Request& req) {
    // 假设 auth_check 已设置
    auto it = req.headers.find("X-User-Uid");
    if (it != req.headers.end()) return it->second;
    return {};
}

auto auth_check = [&](const httplib::Request& req, httplib::Response& res, auto next) {
    auto it = req.headers.find("Authorization");
    if (it == req.headers.end() || it->second.rfind("Bearer ", 0) != 0) {
        res.status = 401;
        res.set_content(make_resp(401, "missing token").dump(), "application/json");
        return;
    }
    const auto token = it->second.substr(7);
    try {
        auto decoded = jwt::decode(token);
        auto verifier = jwt::verify()
            .allow_algorithm(jwt::algorithm::hs256{ kJwtSecret })
            .with_issuer("your-app");
        verifier.verify(decoded);
        // 取出 subject (uid)
        req.set_header("X-User-Uid", decoded.get_subject()); // 或通过其他方式传给后续处理
    }
    catch (const std::exception& e) {
        res.status = 401;
        res.set_content(make_resp(401, "invalid token").dump(), "application/json");
        return;
    }
    next();
    };
