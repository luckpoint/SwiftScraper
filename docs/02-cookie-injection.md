# 02. Cookie 注入

## 目的
対象サイトの認証状態やセッション状態を再現するため、ページロード前に必要な Cookie を `WKHTTPCookieStore` へ注入する。

## 要件
- ロード前に任意の Cookie を挿入できること
- CLI から個別指定と JSON ファイル指定の両方を扱えること
- ドメイン、パス、`Secure` 属性などを適切に指定できること
- Cookie 注入完了後にのみページロードを開始すること

## 入力
- `--cookie <spec>`
- `--cookie-file <path>`
- Cookie 名
- Cookie 値
- ドメイン
- パス
- 有効期限や `Secure` / `HttpOnly` 属性などの付加情報

## 実装済み入力形式
- `--cookie` は `name=session;value=abc123;domain=example.com;path=/;secure=true;httpOnly=true;expires=2026-12-31T00:00:00Z` 形式を受け付ける
- `--cookie-file` は単一オブジェクトまたは配列 JSON を受け付ける
- `expires` は ISO8601 文字列として扱う
- `--cookie` と `--cookie-file` は併用できる

## 処理概要
1. `WKWebsiteDataStore` から `WKHTTPCookieStore` を取得する
2. `--cookie` と `--cookie-file` から Cookie 定義を集約する
3. 必要な Cookie を `HTTPCookie` として組み立てる
4. `setCookie` で順次注入する
5. 完了コールバックを待ってからロード処理へ進む

## 完了条件
- 必要な Cookie が Cookie Store に反映され、ロードを開始してよい状態になること

## 注意点
- `Secure` 付き Cookie は HTTPS 前提となる
- ドメインやパスの不整合があると期待通りに送信されない
- `--cookie-file` は help にあるキー構成に合わせた JSON を前提にする
- サイトによっては Cookie だけでなく `localStorage` や CSRF token が必要になる
