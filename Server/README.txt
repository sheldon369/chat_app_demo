Remove-Item -Recurse -Force .\build  # 若不存在可忽略提示

cmake -B build -S . -G "Visual Studio 17 2022" -A x64 `
  -DCMAKE_TOOLCHAIN_FILE=C:/Users/12435/vcpkg/scripts/buildsystems/vcpkg.cmake `
  -DVCPKG_TARGET_TRIPLET=x64-windows

cmake --build build --config Release

监听服务器开始监听
netstat -ano | find ":8080"

重置adb反向转发
cd F:\leidian\LDPlayer9
.\adb.exe reverse --remove-all
.\adb.exe reverse tcp:8080 tcp:8080
.\adb.exe devices 

.\adb.exe connect 127.0.0.1:5555


adb.exe connect 127.0.0.1:5555

adb -s emulator-5554 shell getprop ro.product.manufacturer

adb -s emulator-5556 shell getprop ro.product.manufacturer
adb -s 127.0.0.1:5555 shell getprop ro.product.manufacturer

.\adb.exe reverse --remove-all
.\adb.exe -s emulator-5556 reverse tcp:8080 tcp:8080
.\adb.exe -s emulator-5554 reverse tcp:8080 tcp:8080
.\adb.exe devices 

adb.exe reverse --remove-all
adb.exe -s emulator-5556 reverse tcp:8080 tcp:8080
adb.exe -s emulator-5554 reverse tcp:8080 tcp:8080
adb.exe devices 


cmd /c "set ADB_SERVER_PORT=5038 && F:\leidian\LDPlayer9\adb.exe kill-server && F:\leidian\LDPlayer9\adb.exe start-server && F:\leidian\LDPlayer9\adb.exe devices"

F:\leidian\LDPlayer9\ldconsole.exe list2


child: ClipOval(
                                      child: auth.hasAvatarUrl
                                          ? Image.network(
                                          user!.avatar!,
                                          fit: BoxFit.cover,
                                      )



