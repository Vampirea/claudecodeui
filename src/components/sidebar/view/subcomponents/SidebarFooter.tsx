import { Settings } from 'lucide-react';
import type { TFunction } from 'i18next';

type SidebarFooterProps = {
  onShowSettings: () => void;
  t: TFunction;
};

export default function SidebarFooter({
  onShowSettings,
  t,
}: SidebarFooterProps) {
  return (
    <div className="flex-shrink-0" style={{ paddingBottom: 'env(safe-area-inset-bottom, 0)' }}>
      <div className="nav-divider" />

      {/* Desktop settings */}
      <div className="hidden px-2 py-2 md:block">
        <button
          className="flex w-full items-center gap-2.5 rounded-lg px-2.5 py-2 text-left text-sm transition-colors hover:bg-accent/80"
          onClick={onShowSettings}
        >
          <Settings className="h-4 w-4 text-muted-foreground" />
          <span className="font-medium text-foreground">{t('actions.settings')}</span>
        </button>
      </div>

      {/* Mobile settings */}
      <div className="px-3 pb-3 pt-2 md:hidden">
        <button
          className="flex h-12 w-full items-center gap-3.5 rounded-xl bg-muted/40 px-4 transition-all hover:bg-muted/60 active:scale-[0.98]"
          onClick={onShowSettings}
        >
          <div className="flex h-8 w-8 items-center justify-center rounded-xl bg-background/80">
            <Settings className="w-4.5 h-4.5 text-muted-foreground" />
          </div>
          <span className="text-base font-medium text-foreground">{t('actions.settings')}</span>
        </button>
      </div>
    </div>
  );
}
