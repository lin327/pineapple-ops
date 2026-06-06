"""
网站/API 状态健康检查脚本
使用 requests 模块发起 HTTP 请求，验证目标服务的可用性。
处理了常见的网络异常情况，并能根据不同的响应类型(JSON/HTML)做安全解析。
"""
import requests

def fetch_api_data(url):
    """
    向指定的 URL 发起 GET 请求，并返回结构化的响应数据。
    
    参数:
        url (str): 需要健康检查或数据获取的目标地址
        
    返回:
        dict: 包含 success, status_code, data, content_type 的字典
    """
    try:
        # 发起 GET 请求到指定 URL，设置 10 秒超时防止长时间挂起
        response = requests.get(url, timeout=10)

        # 检查 HTTP 状态码。如果返回 4XX 或 5XX 错误，会立即触发 HTTPError 异常
        response.raise_for_status()

        # 获取响应头中的 Content-Type，用于判断返回的数据格式
        content_type = response.headers.get('Content-Type', '')

        # 如果返回的是 JSON 格式，则尝试将其解析为 Python 字典/列表
        if 'application/json' in content_type:
            data = response.json()
        # 如果是普通网页 (如 HTML)，为了避免输出过多无用文本，截取前 100 个字符
        else:
            data = response.text[:100] + " ... (正文内容已截断)"

        # 构造并返回标准化的结果结构
        return {
            'success': True,
            'status_code': response.status_code,
            'data': data,
            'content_type': content_type,
        }
        
    # 分类捕获不同类型的请求异常，方便做细粒度排查
    # note: 按异常粒度分类捕获，方便定位问题根因
    except requests.exceptions.HTTPError as http_err:
        print(f"[-] HTTP 错误: {http_err} (可能原因：页面不存在或服务端错误)")
    except requests.exceptions.ConnectionError as conn_err:
        print(f"[-] 连接错误: {conn_err} (可能原因：DNS 解析失败或服务未启动)")
    except requests.exceptions.Timeout as timeout_err:
        print(f"[-] 请求超时: {timeout_err} (可能原因：网络阻塞或后端处理慢)")
    except requests.exceptions.RequestException as req_err:
        print(f"[-] 发生其他网络请求错误: {req_err}")
    
    # 发生异常时，兜底返回标准化的失败结构
    return {
        'success': False,
        'status_code': response.status_code if 'response' in locals() else None,
        'data': None,
        'content_type': None,
    }

if __name__ == "__main__":
    print("=== 开始网站健康检查 ===")
    # ! todo: 替换为实际的目标 URL，当前为占位地址
    target_url = "https://sxxxxxxxxx.site"
    
    print(f"[*] 正在监测目标: {target_url}")
    result = fetch_api_data(target_url)
    
    if result['success']:
        print(f"[+] 状态正常! HTTP响应码: {result['status_code']}")
        print(f"[+] 内容类型: {result['content_type']}")
        print(f"[+] 响应摘要:\n{result['data']}")
    else:
        print(f"[-] 请求失败，目标服务异常。状态码: {result['status_code']}")