/*
 * Copyright 2026 FrankGeary contributors
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later). See the COPYING file in this distribution.
 */

/**
 * Shows additional inbox sections as panels beside the conversation list.
 *
 * Each section is backed by its own conversation monitor: either over an
 * existing folder, or over a private {@link Geary.App.SearchFolder} running
 * a fixed query. Sections are configured via the "inbox-sections" setting.
 */
public class Components.InboxSectionsPanel : Gtk.Box {


    private const int MIN_CONVERSATION_COUNT = 50;

    /** A single section: its own folder, monitor and conversation list. */
    private class Section : Gtk.Box {

        public Geary.App.ConversationMonitor monitor { get; private set; }
        public ConversationList.View list_view { get; private set; }

        /** The search folder backing this section, if it is query-based. */
        public Geary.App.SearchFolder? search_folder { get; private set; }

        /** Whether the section's list is shown. Sections start collapsed. */
        public bool expanded { get; private set; default = false; }

        /** Fired when the section is expanded or collapsed. */
        public signal void expanded_changed();

        private Gtk.Label count_label = new Gtk.Label("");
        private Gtk.Image arrow = new Gtk.Image.from_icon_name(
            "pan-down-symbolic", MENU
        );

        public Section(string name,
                       Geary.Folder folder,
                       Geary.App.SearchFolder? search_folder,
                       Application.Configuration config) {
            Object(orientation: Gtk.Orientation.VERTICAL, spacing: 0);
            this.search_folder = search_folder;

            var title = new Gtk.Label(name);
            title.halign = START;
            title.ellipsize = END;
            title.get_style_context().add_class("heading");

            this.count_label.halign = END;
            this.count_label.hexpand = true;
            this.count_label.get_style_context().add_class("dim-label");

            var header_box = new Gtk.Box(HORIZONTAL, 6);
            header_box.margin_start = 6;
            header_box.margin_end = 6;
            header_box.margin_top = 3;
            header_box.margin_bottom = 3;
            header_box.add(this.arrow);
            header_box.add(title);
            header_box.add(this.count_label);

            // The whole header toggles the section, as in the folder list
            var header = new Gtk.Button();
            header.relief = NONE;
            header.add(header_box);
            header.get_style_context().add_class("geary-inbox-section-header");
            header.clicked.connect(() => set_section_expanded(!this.expanded));

            // A GtkRevealer would size itself to the list's natural height
            // (zero, for a scrolled window) and swallow the section, so the
            // list is simply shown and hidden instead
            this.list_view = new ConversationList.View(config);
            this.list_view.vexpand = true;
            // Otherwise a busy section asks for the height of all its rows
            // and starves the other sections of space
            this.list_view.propagate_natural_height = false;
            this.list_view.height_request = 80;
            // Keep show_all() from revealing the list of a collapsed section
            this.list_view.no_show_all = true;

            this.monitor = new Geary.App.ConversationMonitor(
                folder,
                ConversationList.View.REQUIRED_FIELDS |
                ConversationListBox.REQUIRED_FIELDS |
                ConversationEmail.REQUIRED_FOR_CONSTRUCT,
                MIN_CONVERSATION_COUNT
            );
            this.list_view.set_monitor(this.monitor);

            this.monitor.conversations_added.connect(update_count);
            this.monitor.conversations_removed.connect(update_count);

            pack_start(header, false, false, 0);
            pack_start(new Gtk.Separator(HORIZONTAL), false, false, 0);
            pack_start(this.list_view, true, true, 0);
            show_all();
            sync_expanded_state();
        }

        ~Section() {
            this.monitor.conversations_added.disconnect(update_count);
            this.monitor.conversations_removed.disconnect(update_count);
        }

        public void set_section_expanded(bool expanded) {
            if (this.expanded != expanded) {
                this.expanded = expanded;
                sync_expanded_state();
                expanded_changed();
            }
        }

        /** Applies the expanded state to the widgets, e.g. after show_all(). */
        public void sync_expanded_state() {
            this.list_view.visible = this.expanded;
            this.arrow.icon_name = this.expanded
                ? "pan-down-symbolic"
                : "pan-end-symbolic";
            if (!this.expanded) {
                this.list_view.unselect_all();
            }
        }

        private void update_count() {
            this.count_label.label = this.monitor.size.to_string();
        }

    }


    /** Fired when a conversation is selected in any section. */
    public signal void conversations_selected(
        Gee.Set<Geary.App.Conversation> selected
    );

    /** Fired when a conversation is activated (clicked) in a section. */
    public signal void conversation_activated(
        Geary.App.Conversation activated, uint button
    );

    /** Fired when a section is opened or the last open one is closed. */
    public signal void expansion_changed(bool any_expanded);

    /** The folder of the section whose selection is driving the viewer. */
    public Geary.Folder? active_folder { get; private set; default = null; }

    /** The list of the section whose selection is driving the viewer. */
    public ConversationList.View? active_list { get; private set; default = null; }


    private Application.Configuration config;
    private Gee.List<Section> sections = new Gee.LinkedList<Section>();


    public InboxSectionsPanel(Application.Configuration config) {
        Object(orientation: Gtk.Orientation.VERTICAL, spacing: 0);
        this.config = config;
        get_style_context().add_class("geary-inbox-sections");
    }

    /**
     * Rebuilds the sections for the given account.
     *
     * Sections whose target cannot be resolved are skipped with a warning,
     * so that a typo in the settings does not take the panel down.
     */
    public void load(Geary.Account account) {
        clear();

        var configured = this.config.get_inbox_sections();
        int query_index = 0;
        foreach (var spec in configured) {
            Geary.Folder? folder = null;
            Geary.App.SearchFolder? search = null;

            if (spec.is_folder) {
                folder = find_folder(account, spec.folder_path);
                if (folder == null) {
                    warning(
                        "Inbox section \"%s\": no such folder: %s",
                        spec.name, spec.folder_path
                    );
                    continue;
                }
            } else {
                try {
                    search = new Geary.App.SearchFolder(
                        account,
                        account.local_folder_root,
                        "$GearyInboxSection%d$".printf(query_index++)
                    );
                    var expr_factory = new Util.Email.SearchExpressionFactory(
                        this.config.get_search_strategy(),
                        account.information
                    );
                    search.update_query(
                        account.new_search_query(
                            expr_factory.parse_query(spec.target), spec.target
                        )
                    );
                } catch (GLib.Error err) {
                    warning(
                        "Inbox section \"%s\": bad query \"%s\": %s",
                        spec.name, spec.target, err.message
                    );
                    continue;
                }
                folder = search;
            }

            var section = new Section(spec.name, folder, search, this.config);
            section.list_view.conversations_selected.connect(
                (selected) => on_section_selected(section, selected)
            );
            section.list_view.conversation_activated.connect(
                (activated, button) => conversation_activated(activated, button)
            );

            // Only one section may be open at a time: opening one closes the
            // rest, so the open one gets the whole panel
            section.expanded_changed.connect(() => {
                if (section.expanded) {
                    foreach (var other in this.sections) {
                        if (other != section) {
                            other.set_section_expanded(false);
                        }
                    }
                }
                update_section_packing();
                expansion_changed(section.expanded);
            });

            this.sections.add(section);
            if (this.sections.size > 1) {
                pack_start(new Gtk.Separator(HORIZONTAL), false, false, 0);
            }
            pack_start(section, false, true, 0);

            section.monitor.start_monitoring.begin(
                Geary.Folder.OpenFlags.NO_DELAY,
                null,
                (obj, res) => {
                    try {
                        section.monitor.start_monitoring.end(res);
                    } catch (GLib.Error err) {
                        warning(
                            "Inbox section \"%s\": monitor failed: %s",
                            spec.name, err.message
                        );
                    }
                }
            );
        }

        // show_all() would reveal the lists of collapsed sections, so the
        // state is re-applied afterwards
        show_all();
        foreach (var section in this.sections) {
            section.sync_expanded_state();
        }
        update_section_packing();
    }

    /** Gives the vertical space to the open section, if any. */
    private void update_section_packing() {
        foreach (var section in this.sections) {
            set_child_packing(
                section, section.expanded, true, 0, Gtk.PackType.START
            );
        }
    }

    /** Stops all monitors and removes all sections. */
    public void clear() {
        foreach (var section in this.sections) {
            section.monitor.stop_monitoring.begin(null);
            if (section.search_folder != null) {
                section.search_folder.clear_query();
            }
            remove(section);
        }
        this.sections.clear();
        foreach (var child in get_children()) {
            remove(child);
        }
    }

    /** Closes every section, without re-announcing the change. */
    public void collapse_all() {
        foreach (var section in this.sections) {
            section.set_section_expanded(false);
        }
        update_section_packing();
    }

    /** Clears the selection in every section. */
    public void deselect_all() {
        foreach (var section in this.sections) {
            section.list_view.unselect_all();
        }
        this.active_folder = null;
        this.active_list = null;
    }

    private Geary.Folder? find_folder(Geary.Account account, string path) {
        foreach (var folder in account.list_folders()) {
            if (folder.path.to_string() == path ||
                folder.path.name == path) {
                return folder;
            }
        }
        return null;
    }

    private void on_section_selected(Section source,
                                     Gee.Set<Geary.App.Conversation> selected) {
        if (!selected.is_empty) {
            // Only one list may drive the conversation viewer at a time.
            foreach (var other in this.sections) {
                if (other != source) {
                    other.list_view.unselect_all();
                }
            }
            // Actions must act on this section's folder, not on whatever the
            // folder list has selected
            this.active_folder = source.monitor.base_folder;
            this.active_list = source.list_view;
            conversations_selected(selected);
        }
    }

}
