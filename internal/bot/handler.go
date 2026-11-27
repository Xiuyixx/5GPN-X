package bot

import (
	"context"
	"fmt"
	"strconv"
	"strings"

	"github.com/Xiuyixx/5GPN-X/internal/manage"
)

type Handler struct {
	Client  *TelegramClient
	Manager *manage.Manager
	Admins  map[int64]bool
}

func (h *Handler) Authorized(id int64) bool { return h.Admins[id] }

func (h *Handler) Handle(ctx context.Context, update Update) error {
	if update.Message != nil {
		return h.handleMessage(ctx, *update.Message)
	}
	if update.Callback != nil {
		return h.handleCallback(ctx, *update.Callback)
	}
	return nil
}

func (h *Handler) handleMessage(ctx context.Context, msg Message) error {
	if !h.Authorized(msg.From.ID) {
		return nil
	}
	text := strings.TrimSpace(msg.Text)
	if text == "/start" || text == "/menu" || text == "" {
		return h.Client.SendMessage(ctx, msg.Chat.ID, "5GPN-X Go\n\n请选择管理项目。", h.mainScreen())
	}
	return h.Client.SendMessage(ctx, msg.Chat.ID, "未知命令，请发送 /menu。", h.mainScreen())
}

func (h *Handler) handleCallback(ctx context.Context, cb CallbackQuery) error {
	if !h.Authorized(cb.From.ID) {
		return h.Client.AnswerCallback(ctx, cb.ID, "未授权")
	}
	if cb.Message == nil {
		return h.Client.AnswerCallback(ctx, cb.ID, "消息已失效")
	}
	chatID, messageID := cb.Message.Chat.ID, cb.Message.MessageID
	data := cb.Data
	var text string
	var screen Screen
	var err error
	switch {
	case data == "menu":
		text, screen = "5GPN-X Go\n\n请选择管理项目。", h.mainScreen()
	case data == "apps":
		text, screen = "", AppsScreen(h.Manager.Snapshot())
	case strings.HasPrefix(data, "app:"):
		key := strings.TrimPrefix(data, "app:")
		screen, err = AppScreen(h.Manager.Snapshot(), key)
		text = screen.Text
	case strings.HasPrefix(data, "app-set:"):
		parts := strings.SplitN(strings.TrimPrefix(data, "app-set:"), ":", 2)
		if len(parts) != 2 {
			return h.Client.AnswerCallback(ctx, cb.ID, "设置无效")
		}
		target := parts[1]
		if target == "-" {
			target = ""
		}
		if err = h.Manager.SetApp(parts[0], target); err != nil {
			return h.Client.AnswerCallback(ctx, cb.ID, "设置失败")
		}
		screen, err = AppScreen(h.Manager.Snapshot(), parts[0])
		text = screen.Text
	case data == "exits":
		text, screen = "", ExitsScreen(h.Manager.Snapshot())
	case strings.HasPrefix(data, "exit:"):
		name := strings.TrimPrefix(data, "exit:")
		if err = h.Manager.SetDefault(name); err != nil {
			return h.Client.AnswerCallback(ctx, cb.ID, "切换失败")
		}
		text, screen = "默认出口已更新。", ExitsScreen(h.Manager.Snapshot())
	default:
		return h.Client.AnswerCallback(ctx, cb.ID, "操作已过期")
	}
	if err != nil {
		return err
	}
	if err := h.Client.AnswerCallback(ctx, cb.ID, "已更新"); err != nil {
		return err
	}
	return h.Client.EditMessage(ctx, chatID, messageID, text, screen)
}

func (h *Handler) mainScreen() Screen {
	return Screen{Rows: [][]Button{{{Text: "应用分流", Data: "apps"}, {Text: "出口管理", Data: "exits"}}}}
}

func AdminMap(ids []int64) map[int64]bool {
	out := make(map[int64]bool, len(ids))
	for _, id := range ids {
		out[id] = true
	}
	return out
}

func ParseAdminIDs(values []string) ([]int64, error) {
	out := make([]int64, 0, len(values))
	for _, value := range values {
		id, err := strconv.ParseInt(strings.TrimSpace(value), 10, 64)
		if err != nil {
			return nil, fmt.Errorf("invalid admin id %q", value)
		}
		out = append(out, id)
	}
	return out, nil
}
