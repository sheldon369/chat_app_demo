cmake_minimum_required(VERSION 3.15)
project(Server LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(FetchContent)

set(OPENSSL_ROOT_DIR "C:/Users/12435/vcpkg/installed/x64-windows")

# cpp-httplib
FetchContent_Declare(
  httplib
  GIT_REPOSITORY https://github.com/yhirose/cpp-httplib.git
  GIT_TAG v0.15.3
)
FetchContent_MakeAvailable(httplib)

# nlohmann/json
FetchContent_Declare(
  nlohmann_json
  GIT_REPOSITORY https://github.com/nlohmann/json.git
  GIT_TAG v3.11.3
)
FetchContent_MakeAvailable(nlohmann_json)

#  jwt-cpp
FetchContent_Declare(
  jwt-cpp
  GIT_REPOSITORY https://github.com/Thalhammer/jwt-cpp.git
  GIT_TAG v0.6.0    # 任选稳定 tag
)
FetchContent_MakeAvailable(jwt-cpp)



# 手动指定 sqlite3 库与头文件（来自 vcpkg 安装目录）
set(SQLITE3_LIB "C:/Users/12435/vcpkg/installed/x64-windows/lib/sqlite3.lib")
set(SQLITE3_INC "C:/Users/12435/vcpkg/installed/x64-windows/include")

if(NOT EXISTS "${SQLITE3_LIB}")
    message(FATAL_ERROR "sqlite3.lib not found at: ${SQLITE3_LIB}")
endif()
if(NOT EXISTS "${SQLITE3_INC}")
    message(FATAL_ERROR "sqlite3 include dir not found at: ${SQLITE3_INC}")
endif()

# 创建一个 IMPORTED 目标，避免 find_package
add_library(sqlite3::sqlite3 UNKNOWN IMPORTED)
set_target_properties(sqlite3::sqlite3 PROPERTIES
    IMPORTED_LOCATION "${SQLITE3_LIB}"
    INTERFACE_INCLUDE_DIRECTORIES "${SQLITE3_INC}"
)


add_executable(Server
    Server.cpp
    DBInitializer.cpp
    userHandler.cpp
)


target_include_directories(Server PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(Server PRIVATE 
    httplib::httplib
    nlohmann_json::nlohmann_json
    sqlite3::sqlite3
    jwt-cpp::jwt-cpp 
    bcrypt
  
)

# 如需 HTTPS，可启用：
# target_compile_definitions(chat_demo_server PRIVATE CPPHTTPLIB_OPENSSL_SUPPORT)
# find_package(OpenSSL REQUIRED)
# target_link_libraries(chat_demo_server PRIVATE OpenSSL::SSL OpenSSL::Crypto)

#rm -rf build
#mkdir build
#cd build
#cmake ..
#make