package bot

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"
)

type TelegramClient struct {
	Token   string
	BaseURL string
	HTTP    *http.Client
}

func NewTelegramClient(token string) *TelegramClient {
	return &TelegramClient{Token: token, BaseURL: "https://api.telegram.org", HTTP: &http.Client{Timeout: 40 * time.Second}}
}

type Update struct {
	UpdateID int64          `json:"update_id"`
	Message  *Message       `json:"message,omitempty"`
	Callback *CallbackQuery `json:"callback_query,omitempty"`
}

type Message struct {
	MessageID int64  `json:"message_id"`
	Chat      Chat   `json:"chat"`
	From      User   `json:"from"`
	Text      string `json:"text,omitempty"`
}
type Chat struct {
	ID int64 `json:"id"`
}
type User struct {
	ID int64 `json:"id"`
}
type CallbackQuery struct {
	ID      string   `json:"id"`
	From    User     `json:"from"`
	Message *Message `json:"message,omitempty"`
	Data    string   `json:"data,omitempty"`
}

type inlineButton struct {
	Text   string `json:"text"`
	Data   string `json:"callback_data,omitempty"`
	IconID string `json:"icon_custom_emoji_id,omitempty"`
}
type inlineMarkup struct {
	Rows [][]inlineButton `json:"inline_keyboard"`
}

type apiResponse[T any] struct {
	OK          bool   `json:"ok"`
	Result      T      `json:"result"`
	Description string `json:"description,omitempty"`
}

func (c *TelegramClient) call(ctx context.Context, method string, params map[string]any, out any) error {
	data, err := json.Marshal(params)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.BaseURL+"/bot"+c.Token+"/"+method, bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	var result apiResponse[json.RawMessage]
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return err
	}
	if !result.OK {
		return fmt.Errorf("telegram %s: %s", method, result.Description)
	}
	if out != nil {
		return json.Unmarshal(result.Result, out)
	}
	return nil
}

func (c *TelegramClient) GetUpdates(ctx context.Context, offset int64, timeout int) ([]Update, error) {
	var updates []Update
	err := c.call(ctx, "getUpdates", map[string]any{"offset": offset, "timeout": timeout, "allowed_updates": []string{"message", "callback_query"}}, &updates)
	return updates, err
}
func (c *TelegramClient) SendMessage(ctx context.Context, chatID int64, text string, screen Screen) error {
	return c.call(ctx, "sendMessage", map[string]any{"chat_id": chatID, "text": text, "reply_markup": markup(screen.Rows)}, nil)
}
func (c *TelegramClient) EditMessage(ctx context.Context, chatID, messageID int64, text string, screen Screen) error {
	return c.call(ctx, "editMessageText", map[string]any{"chat_id": chatID, "message_id": messageID, "text": text, "reply_markup": markup(screen.Rows)}, nil)
}
func (c *TelegramClient) AnswerCallback(ctx context.Context, id, text string) error {
	return c.call(ctx, "answerCallbackQuery", map[string]any{"callback_query_id": id, "text": text}, nil)
}

func markup(rows [][]Button) inlineMarkup {
	out := inlineMarkup{Rows: make([][]inlineButton, len(rows))}
	for i, row := range rows {
		for _, b := range row {
			out.Rows[i] = append(out.Rows[i], inlineButton{Text: b.Text, Data: b.Data, IconID: b.IconID})
		}
	}
	return out
}

type OffsetStore struct {
	mu   sync.Mutex
	Path string
}

func (s *OffsetStore) Load() int64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	data, err := osReadFile(s.Path)
	if err != nil {
		return 0
	}
	n, _ := strconv.ParseInt(string(data), 10, 64)
	return n
}
func (s *OffsetStore) Save(offset int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return osWriteFile(s.Path, []byte(strconv.FormatInt(offset, 10)))
}

var osReadFile = os.ReadFile
var osWriteFile = func(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".offset-*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer os.Remove(name)
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(name, path)
}

func Poll(ctx context.Context, client *TelegramClient, store *OffsetStore, handle func(context.Context, Update) error) error {
	offset := store.Load()
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		updates, err := client.GetUpdates(ctx, offset, 30)
		if err != nil {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(time.Second):
				continue
			}
		}
		for _, update := range updates {
			if err := handle(ctx, update); err != nil {
				return err
			}
			if update.UpdateID >= offset {
				offset = update.UpdateID + 1
				if err := store.Save(offset); err != nil {
					return err
				}
			}
		}
	}
}
