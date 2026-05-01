import type {SidebarsConfig} from '@docusaurus/plugin-content-docs';

const sidebars: SidebarsConfig = {
  tutorialSidebar: [
    'intro',
    {
      type: 'category',
      label: 'Tutorials',
      collapsed: false,
      items: [
        'tutorials/first-stream',
      ],
    },
    {
      type: 'category',
      label: 'Guides',
      collapsed: false,
      items: [
        'guides/tuning-hc',
      ],
    },
    {
      type: 'category',
      label: 'Architecture',
      collapsed: false,
      items: [
        'architecture/guarded-wildcopy',
      ],
    },
    {
      type: 'link',
      label: 'API Reference',
      href: '/dart_lz4/api/index.html',
    }
  ],
};

export default sidebars;
