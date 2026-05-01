import type {ReactNode} from 'react';
import clsx from 'clsx';
import Heading from '@theme/Heading';
import { ShieldCheck, Cpu, Library } from 'lucide-react';
import styles from './styles.module.css';

type FeatureItem = {
  title: string;
  icon: ReactNode;
  description: ReactNode;
};

const FeatureList: FeatureItem[] = [
  {
    title: 'Guarded Wildcopy',
    icon: <ShieldCheck size={24} strokeWidth={2} />,
    description: (
      <>
        Optimized 8-byte chunk copying with a fast 32-bit fallback for Web environments. 
        Enjoy native-like decompression speeds without sacrificing bounds safety or Web compatibility.
      </>
    ),
  },
  {
    title: 'Polymorphic Engine',
    icon: <Cpu size={24} strokeWidth={2} />,
    description: (
      <>
        Zero-allocation architecture designed to squeeze maximum performance out of the Dart VM (JIT/AOT). 
        Extremely low garbage collection pressure for high-throughput streaming.
      </>
    ),
  },
  {
    title: 'Reference Standard',
    icon: <Library size={24} strokeWidth={2} />,
    description: (
      <>
        100% compliant with the official LZ4 block and frame specifications, including LZ4HC, 
        skippable frames, legacy formats, and dictionary compression.
      </>
    ),
  },
];

function Feature({title, icon, description}: FeatureItem) {
  return (
    <div className={clsx('col col--4', 'margin-bottom--lg')}>
      <div className={styles.featureCard}>
        <div className={styles.iconWrapper}>
          {icon}
        </div>
        <Heading as="h3" className={styles.featureTitle}>{title}</Heading>
        <p className={styles.featureDescription}>{description}</p>
      </div>
    </div>
  );
}

export default function HomepageFeatures(): ReactNode {
  return (
    <section className={styles.features}>
      <div className="container">
        <div className="row">
          {FeatureList.map((props, idx) => (
            <Feature key={idx} {...props} />
          ))}
        </div>
      </div>
    </section>
  );
}
