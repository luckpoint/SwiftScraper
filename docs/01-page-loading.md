# 01. ページロード

## 目的
`WKWebView` を用いて macOS 上で対象 URL を読み込み、後続のレンダリング待機と HTML 取得へ処理を引き渡す。

## 要件
- 指定 URL を `WKWebView.load(_:)` で読み込めること
- `WKWebViewConfiguration` と `WKWebsiteDataStore` を初期化できること
- 既定では `WKWebsiteDataStore.nonPersistent()` を選べること
- 非表示運用でも適切な frame サイズを維持できること
- ロード成功 / 失敗を delegate で受け取れること

## 入力
- 対象 URL
- WebView の設定値
- Cookie 注入済みの `WKHTTPCookieStore`

## 処理概要
1. `WKWebViewConfiguration` を作成する
2. `WKWebsiteDataStore` を設定する
3. `WKWebView` を生成し、適切な frame を与える
4. `URLRequest` を作成して `load(_:)` を呼ぶ
5. `didFinish` または失敗イベントを受け取る

## 完了条件
- ナビゲーション完了イベントを受け取り、レンダリング待機処理へ進める状態になること

## 注意点
- `didFinish` は最終描画完了ではない
- サイズ 0 の WebView はレスポンシブ表示や lazy load に悪影響を与える

