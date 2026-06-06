import argparse
import os 
# note: 核心解析逻辑 — 逐行扫描，大小写不敏感匹配
def parse_logs(log_file,keyword):
    if not os.path.isfile(log_file):
        print(f"Error: The file '{log_file}' does not exist.")
        return
    print(f"开始扫描 {log_file} 提取关键字: '{keyword}'")
    print("=" * 60)

    found_count = 0
    try:
        with open(log_file, 'r', encoding='utf-8', errors='ignore') as file:
            for line_number, line in enumerate(file,1):
                if keyword.lower() in line.lower():
                    print(f"Line {line_number}: {line.strip()}")
                    found_count += 1
        print("=" * 60)
        print(f"总共找到 {found_count} 行包含关键字 '{keyword}'")

    except PermissionError:
        print(f"❌ 权限不足：无法读取文件 '{log_file}'。请检查文件权限。")
        print("💡 请尝试使用 sudo 管理员权限运行此脚本。")
    except FileNotFoundError:
        print(f"❌ 找不到文件：路径 '{log_file}' 不存在。")
    except MemoryError:
        print(f"❌ 内存不足：日志文件 '{log_file}' 过大，无法处理！")
    except UnicodeDecodeError:
        print(f"❌ 编码错误：文件 '{log_file}' 包含无法解析的特殊字符。")
    except Exception as e:
        print(f"❌ 发生未知错误: {type(e).__name__} - {e}")

def main():
    #设置命令行解析
    parser = argparse.ArgumentParser(description="从日志文件中提取包含指定关键字的行")
    #添加-f / --flie 参数，默认读取mac的ststem.log 日志文件参数
    parser.add_argument("-f", "--file", default="/var/log/system.log", help="要扫描的日志文件路径")
    #添加-k / --keyword 参数，默认提取error关键字
    parser.add_argument("-k","--keyword",default="error", help="要提取的关键字")
    #解析命令行参数
    args = parser.parse_args()
    #调用日志解析函数
    parse_logs(args.file, args.keyword)
if __name__ == "__main__":
    main()