/*
 * Copyright © 2022 John Renner <john@jrenner.net>
 * Copyright © 2022 Cédric Bellegarde <cedric.bellegarde@adishatz.org>
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later). See the COPYING file in this distribution.
 */


/**
 * A conversation list row displaying an email summary
 */
[GtkTemplate (ui = "/org/gnome/Geary/conversation-list-row.ui")]
internal class ConversationList.Row : Gtk.ListBoxRow {

    private Gee.List<Geary.RFC822.MailboxAddress>? user_accounts  {
        owned get {
            return conversation.base_folder.account.information.sender_mailboxes;
        }
    }

    [GtkChild] unowned Gtk.Label preview;
    [GtkChild] unowned Gtk.Label subject;
    [GtkChild] unowned Gtk.Label participants;
    [GtkChild] unowned Gtk.Label date;
    [GtkChild] unowned Gtk.Label count_badge;

    [GtkChild] unowned Gtk.Image flagged_icon;
    [GtkChild] unowned Gtk.Button star_button;
    [GtkChild] unowned Gtk.Button trash_button;

    [GtkChild] unowned Gtk.CheckButton selected_button;

    internal Geary.App.Conversation conversation;
    private Application.Configuration config;
    private DateTime? recv_time;
    private bool selection_enabled = false;
    private bool updating_button = false;

    internal signal void toggle_flag(ConversationList.Row row,
                                     Geary.NamedFlag flag);
    internal signal void trash(ConversationList.Row row);
    internal signal void toggle_selection(ConversationList.Row row,
                                          bool active);

    internal Row(Application.Configuration config,
                 Geary.App.Conversation conversation,
                 bool selection_mode_enabled) {
        this.config = config;
        this.conversation = conversation;

        conversation.email_flags_changed.connect(update_flags);

        config.bind(Application.Configuration.DISPLAY_PREVIEW_KEY,
                    this.preview, "visible");

        this.star_button.clicked.connect(
            () => toggle_flag(this, Geary.EmailFlags.FLAGGED)
        );

        this.trash_button.clicked.connect(() => trash(this));

        // Ticking the box always means "select this", whether or not the list
        // is already in selection mode: it is what starts the selection
        this.selected_button.toggled.connect(on_button_toggled);

        if (selection_mode_enabled) {
            set_selection_enabled(true);
        }

        update();
    }

    internal void update() {
        Geary.Email? last_email = conversation.get_latest_recv_email(
            Geary.App.Conversation.Location.ANYWHERE
        );

        if (last_email != null) {
            var text = Util.Email.strip_subject_prefixes(last_email);
            this.subject.set_text(text);
            var preview_text = last_email.get_preview_as_string();
            this.preview.set_text(
                Geary.String.is_empty_or_whitespace(preview_text)
                    ? "" : "- " + preview_text
            );
            this.recv_time = last_email.properties.date_received.to_local();
            refresh_time();
        }

        this.participants.set_markup(get_participants());

        var count = conversation.get_count();
        if (count > 1) {
            this.count_badge.set_text(conversation.get_count().to_string());
        } else {
            this.count_badge.hide();
        }

        update_flags(null);

    }

    /**
     * Whether the row's check box tracks the list's selection.
     *
     * The box is always visible, as in Gmail, but outside of selection mode it
     * must not tick itself just because the row was selected to be read.
     */
    internal void set_selection_enabled(bool enabled) {
        if (this.selection_enabled == enabled) {
            return;
        }
        this.selection_enabled = enabled;
        if (enabled) {
            this.state_flags_changed.connect(update_button);
            set_button_active(this.is_selected());
        } else {
            this.state_flags_changed.disconnect(update_button);
            set_button_active(false);
        }
    }

    internal void refresh_time() {
        if (this.recv_time != null) {
            // conversation list store sorts by date-received, so display that
            // instead of the sent time
            this.date.set_text(Util.Date.pretty_print(
                this.recv_time,
                this.config.clock_format
            ));
        }
    }

    private void set_button_active(bool active) {
        this.updating_button = true;
        this.selected_button.set_active(active);
        if (active) {
            this.get_style_context().add_class("selected");
            this.set_state_flags(Gtk.StateFlags.SELECTED, false);
        } else {
            this.get_style_context().remove_class("selected");
            this.unset_state_flags(Gtk.StateFlags.SELECTED);
        }
        this.updating_button = false;
    }

    private void update_button() {
        if (!this.updating_button) {
            set_button_active(Gtk.StateFlags.SELECTED in this.get_state_flags());
        }
    }

    private void on_button_toggled() {
        if (!this.updating_button) {
            toggle_selection(this, this.selected_button.get_active());
        }
    }

    private void update_flags(Geary.Email? email) {
        if (conversation.is_unread()) {
            get_style_context().add_class("unread");
        } else {
            get_style_context().remove_class("unread");
        }

        // The star is always shown, as in Gmail: it is an outline when the
        // conversation is not flagged, and clicking it toggles the flag
        var star = this.star_button.get_style_context();
        if (conversation.is_flagged()) {
            this.flagged_icon.icon_name = "starred-symbolic";
            star.add_class("starred");
        } else {
            this.flagged_icon.icon_name = "non-starred-symbolic";
            star.remove_class("starred");
        }
    }

    private string get_participants() {
        var participants = new Gee.ArrayList<Participant>();
        var addresses = new Geary.RFC822.MailboxAddresses();
        Gee.List<Geary.Email> emails = conversation.get_emails(
                          Geary.App.Conversation.Ordering.RECV_DATE_ASCENDING);
        bool is_outgoing = conversation.base_folder.used_as.is_outgoing();
        foreach (Geary.Email message in emails) {
            Geary.RFC822.MailboxAddresses? addrs =
                is_outgoing
                ? message.to
                : message.from;
            addresses = addresses.merge_list(addrs);
        }

        Gee.List<Geary.RFC822.MailboxAddress> list = Geary.traverse(
            addresses.get_all()
        ).filter((address) => {
            // In sent, we only want to show "Me"
            if (is_outgoing && addresses.size > 1) {
                foreach (var account in this.user_accounts) {
                    if (account.equal_to(address)) {
                        return false;
                    }
                }
            }
            return true;
        }).to_array_list();

        foreach (Geary.RFC822.MailboxAddress address in list) {
            Participant participant_display = new Participant(address);
            int existing_index = participants.index_of(participant_display);
            if (existing_index < 0) {
                participants.add(participant_display);
                continue;
            }
        }

        if (participants.size == 0) {
            return "";
        }

        if(participants.size == 1) {
            return participants[0].get_full_markup(this.user_accounts);
        }

        StringBuilder builder = new StringBuilder();
        bool first = true;
        foreach (Participant participant in participants) {
            if (!first) {
                builder.append(", ");
            }

            builder.append(participant.get_short_markup(this.user_accounts));
            first = false;
        }

        return builder.str;
    }
}
