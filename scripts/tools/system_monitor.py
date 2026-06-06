import psutil
import time
from datetime import datetime

# note: 轻量级系统资源监控，适合开发调试使用
def monitor_system():
    print("开始监控系统资源使用情况（按ctrl + c /cmd + c 退出）")
    print ("-" * 60)

    print(f"{'时间':<20} | {'CPU使用率':<15} | {'内存使用率':<15}")
    print ("-" * 60)

    try:
        while True:

            #当前时间戳
            current_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

            # 获取CPU使用率
            cpu_percent = psutil.cpu_percent(interval=1)

            #获取内存使用率
            mem = psutil.virtual_memory()
            mem_percent = mem.percent

            #打印系统资源使用情况
            print(f"{current_time:<20} | {cpu_percent:<15} | {mem_percent:<15}")

            #每隔2秒更新一次系统资源使用情况
            time.sleep(2)

    except KeyboardInterrupt:
        #捕获键盘中断信号，优雅地退出监控
        print ("\n" + "-" * 60)
        print("\n监控已停止。感谢使用！")
if __name__ == "__main__":
    monitor_system()